#!/bin/sh
exec erl -config flood \
     -pa ebin edit deps/*/ebin \
     -boot start_sasl \
     -sname flood_dev \
     -s flood
