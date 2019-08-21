-module(aesophia_http_handler).

-include_lib("aebytecode/include/aeb_fate_data.hrl").

-export([init/2,
         handle_request_json/2,content_types_provided/2,
         allowed_methods/2,content_types_accepted/2
        ]).

-ifdef(TEST).
-export([deserialize/1]).
-endif.

-record(state, { spec :: jsx:json_text()
               , validator :: jesse_state:state()
               , operation_id :: atom() }).

init(Req, OperationId) ->
    JsonSpec = aesophia_http_api_validate:json_spec(),
    Validator = aesophia_http_api_validate:validator(JsonSpec),
    State = #state{ spec = JsonSpec,
                    validator = Validator,
                    operation_id = OperationId },
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    Methods = [<<"GET">>,<<"POST">>],
    {Methods,Req,State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_request_json}], Req, State}.

content_types_provided(Req, State) ->
    {[{<<"application/json">>, handle_request_json}], Req, State}.

handle_request_json(Req0, State = #state{ validator = Validator,
                                          spec = Spec,
                                          operation_id = OperationId }) ->
    Method = cowboy_req:method(Req0),
    try aesophia_http_api_validate:request(OperationId, Method, Req0, Validator) of
        {ok, Params, Req1} ->
            Context = #{ spec => Spec },
            {Code, Headers, Body} = handle_request(OperationId, Params, Context),

            _ = aesophia_http_api_validate:response(OperationId, Method, Code, Body, Validator),

            Req = cowboy_req:reply(Code, to_headers(Headers), jsx:encode(Body), Req1),
            {stop, Req, State};
        {error, Reason, Req1} ->
            Body = jsx:encode(to_error(Reason)),
            Req = cowboy_req:reply(400, #{}, Body, Req1),
            {stop, Req, State}
    catch error:_Error ->
            Body = jsx:encode(to_error({validation_error, <<>>, <<>>})),
            {stop, cowboy_req:reply(400, #{}, Body, Req0), State}
    end.

handle_request('CompileContract', Req, _Context) ->
    case Req of
        #{'Contract' :=
              #{ <<"code">> := Code
               , <<"options">> := Options }} ->
            case compile_contract(Code, Options) of
                 {ok, ByteCode} ->
                     {200, [], #{bytecode => aeser_api_encoder:encode(contract_bytearray, ByteCode)}};
                 {error, ErrorMsg} ->
                     {403, [], #{reason => ErrorMsg}}
             end;
        _ -> {403, [], #{reason => <<"Bad request">>}}
    end;

handle_request('EncodeCalldata', Req, _Context) ->
    case Req of
        #{'FunctionCallInput' :=
              #{ <<"source">>    := ContractCode
               , <<"options">>   := Options
               , <<"function">>  := FunctionName
               , <<"arguments">> := Arguments } } ->
            case encode_calldata(ContractCode, Options, FunctionName, Arguments) of
                {ok, Result} ->
                    {200, [], #{calldata => Result}};
                {error, ErrorMsg} ->
                    {403, [], #{reason => ErrorMsg}}
            end;
        _ -> {403, [], #{reason => <<"Bad request">>}}
    end;

handle_request('DecodeData', Req, _Context) ->
    case Req of
        #{'SophiaBinaryData' :=
              #{ <<"sophia-type">>  := Type
               , <<"data">>  := Data
               }} ->
            case decode_data(Type, Data) of
                {ok, Result} ->
                    {200, [], #{data => Result}};
                {error, ErrorMsg} ->
                    {403, [], #{reason => ErrorMsg}}
            end;
        _ -> {403, [], #{reason => <<"Bad request">>}}
    end;

handle_request('DecodeCalldataBytecode', Req, _Context) ->
    case Req of
        #{ 'DecodeCalldataBytecode' :=
            #{ <<"calldata">> := EncodedCalldata,
               <<"bytecode">> := EncodedBytecode } = Json } ->
            Backend = maps:get(<<"backend">>, Json, <<"default">>),
            case {aeser_api_encoder:safe_decode(contract_bytearray, EncodedCalldata),
                  aeser_api_encoder:safe_decode(contract_bytearray, EncodedBytecode)} of
                {{ok, Calldata}, {ok, Bytecode}} ->
                    decode_calldata_bytecode(Calldata, Bytecode, Backend);
                {{error, _}, _} ->
                    {403, [], #{reason => <<"Bad calldata">>}};
                {_, {error, _}} ->
                    {403, [], #{reason => <<"Bad bytecode">>}}
            end;
        _ -> {403, [], #{reason => <<"Bad request">>}}
    end;

handle_request('DecodeCalldataSource', Req, _Context) ->
    case Req of
        #{ 'DecodeCalldataSource' :=
            #{ <<"calldata">> := EncodedCalldata,
               <<"function">> := FunName,
               <<"source">>   := Source,
               <<"options">>  := Options } } ->
            case aeser_api_encoder:safe_decode(contract_bytearray, EncodedCalldata) of
                {ok, Calldata} ->
                    decode_calldata_source(Calldata, FunName, Source, Options);
                {error, _} ->
                    {403, [], #{reason => <<"Bad calldata">>}}
            end;
        _ -> {403, [], #{reason => <<"Bad request">>}}
    end;

handle_request('DecodeCallResult', Req, _Context) ->
    case Req of
        #{ 'SophiaCallResultInput' :=
           #{ <<"source">>      := Source,
              <<"options">>     := Options,
              <<"function">>    := FunName,
              <<"call-result">> := CallRes,
              <<"call-value">>  := EncodedCallValue } } ->
            case aeser_api_encoder:safe_decode(contract_bytearray, EncodedCallValue) of
                {ok, CallValue} ->
                    decode_call_result(Source, Options, FunName, CallRes, CallValue);
                {error, _} ->
                    {403, [], #{reason => <<"Bad call-value">>}}
            end;
        _ ->
            {403, [], #{reason => <<"Bad request">>}}
    end;

handle_request('GenerateACI', Req, _Context) ->
    case Req of
        #{'Contract' :=
              #{ <<"code">> := Code
               , <<"options">> := Options }} ->
            case generate_aci(Code, Options) of
                 {ok, JsonACI, StringACI} ->
                     {200, [],
                      #{encoded_aci => lists:last(JsonACI),
                        interface   => StringACI}};
                 {error, ErrorMsg} ->
                     {403, [], #{reason => ErrorMsg}}
             end;
        _ -> {403, [], #{reason => <<"Bad request">>}}
    end;

handle_request('Version', _Req, _Context) ->
    case aeso_compiler:version() of
        {ok, Vsn} ->
            {200, [], #{version => Vsn}};
        _ ->
            {500, [], #{reason => <<"Internal error: Could not find the version!?">>}}
    end;

handle_request('APIVersion', _Req, #{ spec := Spec }) ->
    case jsx:decode(Spec, [return_maps]) of
        #{ <<"info">> := #{ <<"version">> := Vsn } } ->
            {200, [], #{'api-version' => Vsn}};
        _ ->
            {500, [], #{reason => <<"Internal error: Could not find the version!?">>}}
    end;

handle_request('Api', _Req, #{ spec := Spec }) ->
    {200, [], jsx:decode(Spec, [return_maps])}.

generate_aci(Contract, Options) ->
    Opts = compile_options(Options),
    case aeso_aci:contract_interface(json, Contract, Opts) of
        {ok, JsonACI} ->
            {ok, StubACI} = aeso_aci:render_aci_json(JsonACI),
            {ok, JsonACI, StubACI};
        {error,_} = Err ->
            Err
    end.

compile_contract(Contract, Options) ->
    Opts = compile_options(Options),
    case aeso_compiler:from_string(binary_to_list(Contract), Opts) of
        {ok, Map} ->
            {ok, serialize(Map)};
        Err = {error, _} ->
            Err
    end.

compile_options(Options) ->
    Map = maps:get(<<"file_system">>, Options, #{}),
    Map1 = maps:from_list([{binary_to_list(N), F} || {N, F} <- maps:to_list(Map)]),
    SrcFile = maps:get(<<"src_file">>, Options, no_file),
    Backend = case binary_to_atom(maps:get(<<"backend">>, Options, <<"default">>), utf8) of
                  aevm    -> aevm;
                  fate    -> fate;
                  default -> fate
              end,
    [{backend, Backend}, {include, {explicit_files, Map1}}]
      ++ [ {src_file, binary_to_list(SrcFile)} || SrcFile /= no_file ].

encode_calldata(Source, Options, Function, Arguments) ->
    COpts = compile_options(Options),
    case aeso_compiler:create_calldata(binary_to_list(Source),
                                       binary_to_list(Function),
                                       lists:map(fun binary_to_list/1, Arguments),
                                       COpts) of
        {ok, Calldata} ->
            {ok, aeser_api_encoder:encode(contract_bytearray, Calldata)};
        Err = {error, _} ->
            Err
    end.

decode_data(Type, Data) ->
    case aeser_api_encoder:safe_decode(contract_bytearray, Data) of
        {error, _} ->
            {error, <<"Data must be encoded as a contract_bytearray">>};
        {ok, CallData} ->
            try decode_data_(Type, CallData) of
                {ok, _Result} = OK -> OK;
                {error, _ErrorMsg} = Err -> Err
            catch
                _T:_E ->
                    String = io_lib:format("~p:~p ~p", [_T,_E,erlang:get_stacktrace()]),
                    Error = << <<B>> || B <- "Bad argument: " ++ lists:flatten(String) >>,
                    {error, Error}
            end
    end.

decode_data_(Type, Data) ->
    case parse_type(Type) of
        {ok, VMType} ->
            try aeb_heap:from_binary(VMType, Data) of
                {ok, Term} ->
                    try prepare_for_json(VMType, Term) of
                        R -> {ok, R}
                    catch throw:R -> R
                    end;
                {error, _} -> {error, <<"bad type/data">>}
            catch _T:_E ->    {error, <<"bad argument">>}
            end;
        {error, _} = E -> E
    end.

parse_type(BinaryString) ->
    String = unicode:characters_to_list(BinaryString, utf8),
    case aeso_compiler:sophia_type_to_typerep(String) of
        {ok, _Type} = R -> R;
        {error, ErrorAtom} ->
            {error, unicode:characters_to_binary(atom_to_list(ErrorAtom))}
    end.

decode_calldata_bytecode(Calldata, SerialBytecode, BackendBin) ->
    Backend = binary_to_atom(BackendBin, utf8),
    case deserialize(SerialBytecode) of
        %% Try a bit to be clever, if backend is not set - do some
        %% rudimentary auto detection.
        {ok, #{type_info := [], byte_code := Bytecode}} when Backend == default ->
            decode_calldata_bytecode_(fate, Calldata, Bytecode);
        {ok, #{type_info := TypeInfo}} when Backend == default; Backend == aevm ->
            decode_calldata_bytecode_(aevm, Calldata, TypeInfo);
        {ok, #{byte_code := Bytecode}} when Backend == fate ->
            decode_calldata_bytecode_(fate, Calldata, Bytecode);
        {error, _} ->
            {403, [], #{reason => <<"Could not deserialize Bytecode">>}}
    end.

decode_calldata_bytecode_(aevm, Calldata, TypeInfo) ->
    case aeb_aevm_abi:get_function_hash_from_calldata(Calldata) of
        {ok, Hash} ->
            case {aeb_aevm_abi:function_name_from_type_hash(Hash, TypeInfo),
                  aeb_aevm_abi:typereps_from_type_hash(Hash, TypeInfo)} of
                {{ok, FunName}, {ok, ArgType, _OutType}} ->
                    case aeb_heap:from_binary({tuple, [word, ArgType]}, Calldata) of
                        {ok, {_Hash, VMArgs}} ->
                            prepare_calldata_response(FunName, ArgType, VMArgs);
                        {error, _} ->
                            {403, [], #{reason => <<"Could not interpret Calldata as heap">>}}
                    end;
                {{error, _}, _} ->
                    {403, [], #{reason => <<"Could not find function hash in Typeinfo">>}};
                {_, {error, _}} ->
                    {403, [], #{reason => <<"Could not encode typerep for Arguments">>}}
            end;
        {error, _} ->
            {403, [], #{reason => <<"Could not find function hash in Calldata">>}}
    end;
decode_calldata_bytecode_(fate, Calldata, SerBytecode) ->
    try aeb_fate_code:deserialize(SerBytecode) of
        Bytecode ->
            case aeb_fate_encoding:deserialize(Calldata) of
              {tuple, {FunHash, {tuple, TArgs}}} ->
                  decode_calldata_fatecode(FunHash, tuple_to_list(TArgs), Bytecode);
              _ ->
                  {403, [], #{reason => <<"Bad Calldata">>}}
            end
    catch _:_ ->
        {403, [], #{reason => <<"Could not deserialize FATE bytecode">>}}
    end.

decode_calldata_fatecode(FunHash, Args, FCode) ->
    case aeb_fate_abi:get_function_name_from_function_hash(FunHash, FCode) of
        {ok, FunName} ->
            {200, [], #{function => FunName,
                        arguments => [fate_to_json(Arg) || Arg <- Args]}};
        _ ->
            {403, [], #{reason => <<"Could not find function hash in FATE bytecode">>}}
    end.


prepare_calldata_response(FunName, ArgType, VMArgs) ->
    try #{ <<"type">>  := <<"tuple">>,
           <<"value">> := ArgsList } = prepare_for_json(ArgType, VMArgs),
        {200, [], #{ function  => FunName,
                     arguments => ArgsList }}
    catch _:_Reason ->
        {403, [], #{reason => <<"Error preparing JSON">>}}
    end.

decode_calldata_source(Calldata, FunName, Source, Options) ->
    COpts = compile_options(Options),
    case aeso_compiler:decode_calldata(binary_to_list(Source),
                                       binary_to_list(FunName),
                                       Calldata, COpts) of
        {ok, ArgTypes, Values} ->
            Ts = [ aeso_aci:json_encode_type(T) || T <- ArgTypes ],
            Vs = [ aeso_aci:json_encode_expr(V) || V <- Values ],
            {200, [], #{ function => FunName
                       , arguments => [ #{ type => T, value => V }
                                        || {T, V} <- lists:zip(Ts, Vs) ] }};
        {error, E} ->
            {403, [], #{ reason => iolist_to_binary(E) }}
    end.

decode_call_result(Source, Options, FunName, CallRes, CallValue) ->
    COpts = compile_options(Options),
    case aeso_compiler:to_sophia_value(binary_to_list(Source), binary_to_list(FunName),
                                       bin_to_res_atom(CallRes), CallValue, COpts) of
        {ok, Ast} ->
            {200, [], aeso_aci:json_encode_expr(Ast)};
        {error, E} ->
            {403, [], #{ reason => iolist_to_binary(E) }}
    end.


%% -- Helper functions -------------------------------------------------------

bin_to_res_atom(<<"ok">>)     -> ok;
bin_to_res_atom(<<"revert">>) -> revert;
bin_to_res_atom(<<"error">>)  -> error.


%% -- Contract serialization
-define(SOPHIA_CONTRACT_VSN, 2).
-define(SOPHIA_CONTRACT_VSN_1, 1).
-define(COMPILER_SOPHIA_TAG, compiler_sophia).

serialize(#{byte_code := ByteCode, type_info := TypeInfo,
            contract_source := ContractString, compiler_version := Version}) ->
    ContractBin      = list_to_binary(ContractString),
    {ok, SourceHash} = eblake2:blake2b(32, ContractBin),
    Fields = [ {source_hash, SourceHash}
             , {type_info, TypeInfo}
             , {byte_code, ByteCode}
             , {compiler_version, Version} ],
    aeser_chain_objects:serialize(?COMPILER_SOPHIA_TAG,
                                  ?SOPHIA_CONTRACT_VSN,
                                  serialization_template(?SOPHIA_CONTRACT_VSN),
                                  Fields).

deserialize(Binary) ->
    case aeser_chain_objects:deserialize_type_and_vsn(Binary) of
        {compiler_sophia = Type, ?SOPHIA_CONTRACT_VSN_1 = Vsn, _Rest} ->
            Template = serialization_template(Vsn),
            [ {source_hash, Hash}
            , {type_info, TypeInfo}
            , {byte_code, ByteCode}
            ] = aeser_chain_objects:deserialize(Type, Vsn, Template, Binary),
            {ok, #{ source_hash => Hash
                  , type_info => TypeInfo
                  , byte_code => ByteCode
                  , contract_vsn => Vsn
                  }};
        {compiler_sophia = Type, ?SOPHIA_CONTRACT_VSN = Vsn, _Rest} ->
            Template = serialization_template(Vsn),
            [ {source_hash, Hash}
            , {type_info, TypeInfo}
            , {byte_code, ByteCode}
            , {compiler_version, CompilerVersion}
            ] = aeser_chain_objects:deserialize(Type, Vsn, Template, Binary),
            {ok, #{ source_hash => Hash
                  , type_info => TypeInfo
                  , byte_code => ByteCode
                  , compiler_version => CompilerVersion
                  , contract_vsn => Vsn
                  }};
        Other ->
            {error, {illegal_code_object, Other}}
    end.

serialization_template(?SOPHIA_CONTRACT_VSN_1) ->
    [ {source_hash, binary}
    , {type_info, [{binary, binary, binary, binary}]} %% {type hash, name, arg type, out type}
    , {byte_code, binary} ];
serialization_template(?SOPHIA_CONTRACT_VSN) ->
    [ {source_hash, binary}
    , {type_info, [{binary, binary, binary, binary}]} %% {type hash, name, arg type, out type}
    , {byte_code, binary}
    , {compiler_version, binary} ].

to_headers(Headers) when is_list(Headers) ->
    maps:from_list(Headers).

to_error({Reason, Name, Info}) ->
    #{ reason => Reason,
       parameter => Name,
       info => Info }.

%% -- JSON representation for typed VM-value
prepare_for_json(word, Integer) when is_integer(Integer) ->
    #{ <<"type">> => <<"word">>,
       <<"value">> => Integer};
prepare_for_json(string, String) when is_binary(String) ->
    #{ <<"type">> => <<"string">>,
       <<"value">> => String};
prepare_for_json({option, _T}, none) ->
    #{ <<"type">> => <<"option">>,
       <<"value">> => <<"None">>};
prepare_for_json({option, T}, {some, E}) ->
    #{ <<"type">> => <<"option">>,
       <<"value">> => prepare_for_json(T,E) };
prepare_for_json({tuple, Ts}, Es) ->
    #{ <<"type">> => <<"tuple">>,
       <<"value">> => [prepare_for_json(T,E)
                       || {T,E} <-
                              lists:zip(Ts, tuple_to_list(Es))] };
prepare_for_json({list, T}, Es) ->
    #{ <<"type">> => <<"list">>,
       <<"value">> => [prepare_for_json(T,E) || E <- Es]};
prepare_for_json(T = {variant, Cons}, R = {variant, Tag, Args}) when is_integer(Tag), Tag < length(Cons) ->
    Ts = lists:nth(Tag + 1, Cons),
    case length(Ts) == length(Args) of
        true ->
            #{ <<"type">> => <<"variant">>
             , <<"value">> => [Tag | [prepare_for_json(ArgT, Arg)
                                      || {ArgT, Arg} <- lists:zip(Ts, Args)]] };
        false ->
            String = io_lib:format("Type: ~p Res:~p", [T,R]),
            Error = << <<B>> || B <- "Invalid Sophia type: " ++ lists:flatten(String) >>,
            throw({error, Error})
    end;
prepare_for_json({map, KeyT, ValT}, Map) when is_map(Map) ->
    #{ <<"type">> => <<"map">>,
       <<"value">> => [ #{ <<"key">> => prepare_for_json(KeyT, K),
                           <<"val">> => prepare_for_json(ValT, V) }
                        || {K, V} <- maps:to_list(Map) ] };
prepare_for_json(T, R) ->
    String = io_lib:format("Type: ~p Res:~p", [T,R]),
    Error = << <<B>> || B <- "Invalid VM-type: " ++ lists:flatten(String) >>,
    throw({error, Error}).

jo(T, V) -> #{ <<"type">> => atom_to_binary(T, utf8), <<"value">> => V }.

fate_to_json(?FATE_ADDRESS(Bin))  -> jo(address, aeser_api_encoder:encode(account_pubkey, Bin));
fate_to_json(?FATE_ORACLE(Bin))   -> jo(oracle, aeser_api_encoder:encode(oracle_pubkey, Bin));
fate_to_json(?FATE_ORACLE_Q(Bin)) -> jo(oracle_query, aeser_api_encoder:encode(oracle_query_id, Bin));
fate_to_json(?FATE_CONTRACT(Bin)) -> jo(contract, aeser_api_encoder:encode(contract_pubkey, Bin));
fate_to_json(?FATE_BYTES(Bin))    -> jo(bytes, aeser_api_encoder:encode(bytearray, Bin));
fate_to_json(?FATE_BITS(Bin))     -> jo(bits, aeser_api_encoder:encode(bytearray, Bin));
fate_to_json(N) when ?IS_FATE_INTEGER(N) -> jo(int, ?FATE_INTEGER_VALUE(N));
fate_to_json(B) when ?IS_FATE_BOOLEAN(B) -> jo(bool, ?FATE_BOOLEAN_VALUE(B));
fate_to_json(S) when ?IS_FATE_STRING(S)  -> jo(string, ?FATE_STRING_VALUE(S));
fate_to_json(List) when ?IS_FATE_LIST(List) -> jo(list, [fate_to_json(X) || X <- ?FATE_LIST_VALUE(List)]);
fate_to_json(?FATE_UNIT) -> jo(unit, <<>>);
fate_to_json(?FATE_TUPLE(Val)) -> jo(tuple, [fate_to_json(X) || X <- tuple_to_list(Val)]);
fate_to_json(Map) when ?IS_FATE_MAP(Map) -> jo(map, [ #{<<"key">> => fate_to_json(Key),
                                                        <<"val">> => fate_to_json(Val)}
                                                      || {Key, Val} <- maps:to_list(?FATE_MAP_VALUE(Map)) ]);
fate_to_json({variant, _Ar, Tag, Args}) -> jo(variant, [Tag | [fate_to_json(Arg) || Arg <- tuple_to_list(Args)]]);
fate_to_json(_Data) -> throw({cannot_translate_to_json, _Data}).
