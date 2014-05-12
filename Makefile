all: compile

test: compile
	@./rebar skip_deps=true eunit

get-deps:
	@./rebar get-deps

update-deps:
	@./rebar update-deps

compile: get-deps
	@./rebar compile

clean:
	@./rebar clean

dev: compile
	@erl -noshell -pa ebin/ \
					deps/*/ebin/ \
		-eval 'application:start(uuid)' \
		-eval 'application:start(alley_dto)' \
		-eval 'adto_just_tests:just_sms_response_test()' \
		-s init stop

tags:
	@find . -name "*.[e,h]rl" -print | etags -
