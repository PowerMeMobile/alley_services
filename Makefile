all: xref

get-deps:
	@./rebar get-deps

update-deps:
	@./rebar update-deps

compile: get-deps
	@./rebar compile

xref: compile
	@./rebar xref skip_deps=true

clean:
	@./rebar clean

dev: compile
	@erl -noshell -pa ebin/ \
					deps/*/ebin/ \
		-eval 'application:start(uuid)' \
		-eval 'application:start(alley_dto)' \
		-eval 'adto_just_tests:just_sms_response_test()' \
		-s init stop

test: compile
	@./rebar skip_deps=true eunit

tags:
	@find . -name "*.[e,h]rl" -print | etags -
