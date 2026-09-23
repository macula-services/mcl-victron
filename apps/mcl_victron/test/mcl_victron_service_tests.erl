%% @doc The service contract, asserted locally.
%%
%% mcl_om resolves the six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% `-behaviour(mcl_om_service)' attribute turns that into a compile error; this
%% suite asserts what the compiler cannot see: the shapes inside the callbacks,
%% the store named in two places, and the pinned runtime.
-module(mcl_victron_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, mcl_victron).
-define(SERVICE, mcl_victron_service).

exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    ?assertEqual([], [F || {N, A} = F <- Required,
                           not erlang:function_exported(?SERVICE, N, A)]).

declares_the_behaviour_test() ->
    Attrs = ?SERVICE:module_info(attributes),
    ?assert(lists:member(mcl_om_service, proplists:get_value(behaviour, Attrs, []))).

%% The OTP application is snake_case, the repo, image and mesh name kebab-case.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    ?assertEqual(<<"mcl-victron">>, Wire),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

%% Nothing callable: the readings are the output.
advertises_nothing_test() ->
    ?assertEqual([], ?SERVICE:capabilities()).

identity_spec_names_the_scope_test() ->
    #{scope := Scope, actions := Actions, resources := Resources, ttl_days := Ttl} =
        ?SERVICE:identity_spec(),
    ?assertEqual(<<"mcl-victron">>, Scope),
    ?assert(lists:all(fun is_binary/1, Actions ++ Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% ⚠ THE STORE IS NAMED TWICE: store_id/0, which mcl_om opens, and the evoq
%% block of the release config, which evoq resolves. Disagreeing opens one
%% store and addresses another.
the_store_is_the_one_evoq_is_configured_for_test() ->
    %% Read, not consulted: the ${VAR} placeholders are not Erlang terms.
    Named = pinned("config/sys.config.src", "\\{store_id,\\s+([a-z_]+)\\}"),
    ?assertEqual(atom_to_binary(?SERVICE:store_id()), Named).

the_store_is_the_one_the_command_dispatches_to_test() ->
    {ok, Source} = file:read_file(alongside(
                     "apps/mcl_victron/src/record_victron_reading/maybe_record_victron_reading.erl")),
    ?assertNotEqual(nomatch, binary:match(Source, atom_to_binary(?SERVICE:store_id()))).

the_data_dir_follows_the_environment_test() ->
    os:putenv("MCL_DATA_DIR", "/data"),
    ?assertEqual("/data", ?SERVICE:data_dir()),
    os:unsetenv("MCL_DATA_DIR").

%% A receiver retrying a wrong or absent broker forever is alive and useless;
%% health is whether readings can arrive.
not_connected_is_degraded_test() ->
    ?assertEqual({degraded, not_connected_to_gx}, ?SERVICE:hearing(disconnected, 10_000, 30_000)).

connected_and_heard_is_ok_test() ->
    ?assertEqual(ok, ?SERVICE:hearing({connected, 0}, 45_000, 30_000)).

a_silent_gx_is_degraded_test() ->
    ?assertEqual({degraded, {gx_silent_ms, 45_001}},
                 ?SERVICE:hearing({connected, 0}, 45_001, 30_000)).

%%==============================================================================
%% The runtime is pinned in four places and they must agree
%%==============================================================================

%% The builder image (by digest), the CI image's toolchain check, .tool-versions
%% and the VM running this test. A floating `erlang:28' once shipped OTP 28.5 to
%% the fleet while every check stayed green.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Image = pinned("Containerfile",
                   "^FROM docker\\.io/(?:hexpm/)?erlang:([0-9]+\\.[0-9]+\\.[0-9]+)"
                   "-alpine[^@\\s]*@sha256:[0-9a-f]{64} AS builder$"),
    Ci = pinned(".github/workflows/lint-and-test.yml",
                "\\{<<\"([0-9]+\\.[0-9]+\\.[0-9]+)\">>, true\\} -> halt\\(0\\);"),
    Tools = pinned(".tool-versions", "^erlang ([0-9]+\\.[0-9]+\\.[0-9]+)$"),
    ?assertEqual([Image], lists:usort([Image, Ci, Tools, running_otp()])).

image_build_pins_rebar3_by_sha256_test() ->
    {ok, Containerfile} = file:read_file(alongside("Containerfile")),
    ?assertMatch({match, _}, re:run(Containerfile, "releases/download/3\\.27\\.0/rebar3")),
    ?assertMatch({match, _}, re:run(Containerfile, "\\b[0-9a-f]{64}  /usr/local/bin/rebar3")),
    ?assertEqual(nomatch, binary:match(Containerfile, <<"s3.amazonaws.com/rebar3">>)).

lint_runs_on_no_floating_image_test() ->
    {ok, Lint} = file:read_file(alongside(".github/workflows/lint-and-test.yml")),
    ?assertMatch({match, _},
                 re:run(Lint, "image: ghcr\\.io/macula-io/macula-ci-otp:[0-9]{8}-[0-9]{4}@sha256:[0-9a-f]{64}$",
                        [multiline])).

running_otp() ->
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases",
                                                  erlang:system_info(otp_release),
                                                  "OTP_VERSION"])),
    string:trim(Version).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern, [multiline, {capture, all_but_first, binary}]),
    Version.

%% Relative to the beam rather than the working directory.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) -> climb(filename:dirname(Dir), Name, Left - 1).
