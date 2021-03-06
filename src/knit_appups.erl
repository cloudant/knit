% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(knit_appups).


-export([
    generate/2
]).


-include_lib("sasl/src/systools.hrl").
-include("knit.hrl").


generate(FromRels, ToRel) ->
    knit_log:debug("Generating appups."),
    Upgrades = apps_to_upgrade(FromRels, ToRel),

    OldAppVersions = lists:map(fun(Upgrade) ->
        generate_appup(Upgrade)
    end, Upgrades),

    % We add the versions from ToRel because of the implicit
    % support for upgrading to the same version (ie, its a no-op).
    add_new_app_versions(ToRel, OldAppVersions).


apps_to_upgrade(FromRels, {_, _, ToRelApps}) ->
    % Get a reference list of new {Name, Vsn} pairs.
    ToRelNameVsns = [NV || {NV, _} <- ToRelApps],

    % An application is considered to be an upgrade if
    % it exists in ToRel with a different version. There
    % isn't any assertion done on version ordering.
    Upgraded = lists:flatmap(fun({_FRelFile, _FRelInfo, FromRelApps}) ->
        lists:filter(fun({{Name, FromVsn}, _}) ->
            case lists:keyfind(Name, 1, ToRelNameVsns) of
                {Name, ToVsn} when FromVsn /= ToVsn ->
                    true;
                _ ->
                    false
            end
        end, FromRelApps)
    end, FromRels),

    % An application may exist in two previous releases at
    % the same version. This just removes any duplicates
    % as defined by {Name, Vsn}. There is no check to see
    % if a user did something crazy to include different
    % code with the same name and version in two releases.
    UniqueUpgraded = lists:usort(fun({NV1, _}, {NV2, _}) ->
        NV1 =< NV2
    end, Upgraded),

    % Finally, group applications so that we have
    % a list of old versions paired with the new
    % version.
    Grouped = lists:foldl(fun({{Name, _}, _}=App, Acc) ->
        dict:append(Name, App, Acc)
    end, dict:new(), UniqueUpgraded),
    Final = lists:flatmap(fun({{Name, _}, _}=App) ->
        case dict:find(Name, Grouped) of
            {ok, OldVsns} ->
                [{OldVsns, App}];
            error ->
                []
        end
    end, ToRelApps),

    % Log the final upgrades we've found
    lists:foreach(fun({OldApps, {{Name, NewVsn}, _}}) ->
        OldVsns = [V || {{_, V}, _} <- OldApps],
        knit_log:debug("Upgrading ~s: ~p -> ~p", [Name, OldVsns, NewVsn])
    end, Final),

    Final.


generate_appup({OldVsns, {{Name, _}, _} = NewVsn}) ->
    case filelib:is_regular(appup_path(NewVsn)) of
        true ->
            knit_log:info("~s.appup exists", [Name]),
            {Name, read_versions_from_appup(NewVsn)};
        false ->
            {FinalOldVsns, Appup} = generate_appup(OldVsns, NewVsn),
            write_appup(NewVsn, Appup),
            {Name, FinalOldVsns}
    end.


add_new_app_versions({_, _, ToRelApps}, OldVsns) ->
    lists:foldl(fun({{Name, Vsn}, _}, Acc) ->
        dict:append(Name, Vsn, Acc)
    end, dict:from_list(OldVsns), ToRelApps).


generate_appup(OldApps, {{_NewName, NewVsn}, _} = NewApp) ->
    Instructions = lists:map(fun(Old) ->
        generate_instructions(Old, NewApp)
    end, OldApps),
    % Only return the FinalOldVsns we're including because
    % we may want generate_instructions/2 to be able to
    % filter some versions through user code so this accounts
    % for the future possibility of users removing some
    % upgrades.
    FinalOldVsns = [V || {V, _, _} <- Instructions],
    UpFrom = [{V, Is} || {V, Is, _} <- Instructions],
    DownTo = [{V, Is} || {V, _, Is} <- Instructions],
    AppUp = {NewVsn, UpFrom, DownTo},
    {FinalOldVsns, AppUp}.


generate_instructions({{_OldName, OldVsn}, OldApp}, {_, NewApp}) ->
    OldDir = OldApp#application.dir,
    NewDir = NewApp#application.dir,
    {Removed0, Added0, Changed0} = knit_beam_lib:cmp_dirs(OldDir, NewDir),
    Removed = [{removed, R} || R <- Removed0],
    Added = [{added, A} || A <- Added0],
    Changed = [{changed, C} || C <- Changed0],
    % We're returning UpFrom and DownTo instructions
    % here. Granted we don't actually generate DownTo
    % instructions but we may. At some point. Perhaps.
    {OldVsn, knit_kmod:render(Removed ++ Added ++ Changed), []}.


read_versions_from_appup({{Name, Vsn}, App}) ->
    Filename = appup_path(App),
    case file:consult(Filename) of
        {ok, [Appup]} ->
            validate_appup(Filename, Appup),
            {_, UpFrom, _} = Appup,
            [V || {V, _} <- UpFrom];
        {ok, _} ->
            Fmt = "Invalid appup found in ~s ~s",
            ?BAD_CONFIG(Fmt, [Name, Vsn]);
        {error, Error} ->
            Reason = file:format_error(Error),
            ?IO_ERROR("Error reading appup ~s: ~s", [Filename, Reason])
    end.


write_appup({_, App}, Appup) ->
    Filename = appup_path(App),
    validate_appup(Filename, Appup),
    Now = httpd_util:rfc1123_date(erlang:localtime()),
    Header = "%% Generated by knit: " ++ Now ++ "\n\n",
    Body = io_lib:print(Appup),
    case file:write_file(Filename, Header ++ Body ++ ".\n\n") of
        ok ->
            ok;
        {error, Error} ->
            Reason = file:format_error(Error),
            ?IO_ERROR("Failed to write ~s: ~s", [Filename, Reason])
    end.


validate_appup(Filename, {_NewVsn, UpFrom, DownTo}) ->
    UpVsns = lists:sort([V || {V, _} <- UpFrom]),
    DownVsns = lists:sort([V || {V, _} <- DownTo]),
    if UpVsns == DownVsns -> ok; true ->
        ?BAD_CONFIG("Mismatched upgrade/down verions in ~s", [Filename])
    end.


appup_path(#application{name=Name, dir=Dir}) ->
    Basename = atom_to_list(Name) ++ ".appup",
    filename:join(Dir, Basename);
appup_path({_, #application{}=A}) ->
    appup_path(A).
