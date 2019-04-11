# Stream connections
If we say something like `$stdin >> $stdout`, who owns the fact that these two
things are connected? Presumably whoever's multiplexing FDs. What's the API to
add/remove connections from inside other streams?
