%% Fast splitting for the ASCII files jantar parses (/proc, /sys, tool
%% output). gleam/string's split and replace go through Erlang's Unicode-aware
%% string module, which walks grapheme clusters; binary:split is a BIF that
%% scans bytes. On this machine it cut the CPU sensor's cost several-fold.
-module(jantar_core_ffi).
-export([lines/1, fields/1]).

%% Lines, as string.split(text, "\n") would give them (empty ones kept).
lines(Text) -> binary:split(Text, <<"\n">>, [global]).

%% Whitespace-separated fields, with no empty strings.
fields(Text) -> binary:split(Text, [<<" ">>, <<"\t">>, <<"\n">>], [global, trim_all]).
