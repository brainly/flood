#!/bin/sh
exec erl -pa ebin edit deps/*/ebin -boot start_sasl \
    -sname flood_dev \
     -s flood
