[![Actions Status](https://github.com/raku-community-modules/App-MoarVM-Debug/actions/workflows/linux.yml/badge.svg)](https://github.com/raku-community-modules/App-MoarVM-Debug/actions) [![Actions Status](https://github.com/raku-community-modules/App-MoarVM-Debug/actions/workflows/macos.yml/badge.svg)](https://github.com/raku-community-modules/App-MoarVM-Debug/actions) [![Actions Status](https://github.com/raku-community-modules/App-MoarVM-Debug/actions/workflows/windows.yml/badge.svg)](https://github.com/raku-community-modules/App-MoarVM-Debug/actions)

App::MoarVM::Debug
==================

The interactive MoarVM debugger installs a script called `raku-remote-debug` that allows a developer to start a Raku program in debugger mode which allows the developer to step through the program and perform various types of introspection.

Starting the debugger
-------------------------

    $ raku-remote-debug your-program.raku arg1 arg2

Starting a program in debugger mode is as simple as replacing `raku` by `raku-remote-debug` on the command line. That's it.

When it is started this way, it will show a text on STDERR such as:

    Running with debugging enabled at localhost port 27434


You would typically then set breakpoints or do some introspection. And then start the program by typing "resume" to lift the suspension of all threads in the program.

Type "help" in the debugger's CLI to see what commands are available to you.

Limitations
-----------

The debugger uses a single port to communicate between your program and the debugger. By default this is port `27434`.

This means that on any given computer, only one program can be debugged this way, and only one debugger can run at the same time.

Should you need to have more debuggers running at the same time, or for some reason you need to use another port, you can set the environment variable `MVM_DEBUG_PORT` to the port you'd like to use or pass `--port` argument to the debugger.

To start the debugger:

    $ MVM_DEBUG_PORT=4242 raku-remote-debug your-program.raku arg1 arg2

  or

    $ raku-remote-debug --port=2666 your-program.raku arg1 arg2

Some hints
----------

  * (Optional) Write `assume thread 1` to assume tracking of first (main) thread

  * Set a breakpoint

    > breakpoint "my-script.raku" 1234 1 1

The string is the filename and `1234` is the line number (`1 1` is the secret ingredient). Ensure the line number doesn't point to an empty line.

  * Type `resume` to run your script.

  * The breakpoint will trigger, you can type `all lexicals` to view all lexicals. The numbers shown next to them in bold are "handle" numbers.

  * Find the object you want to dump and type `metadata 1234` (`1234` is the handle number).

If the features includes `attributes`, you can enter `attributes 1234` for this object to get information about the object's attributes.

If the features includes `positional`, you can enter `positionals 1234` to get information about the positional elements of the object.

If the features includes `associative`, you can enter `associatives 1234` to get information about the associative elements (keys and values) of the object.

The `metadata` command is only needed if you don't know which of these commands is useful for any given type.

  * Type `help` to see all of the available commands.

Known Issues
------------

The only stepping mode currently available is Step Into.

Backtraces will show incorrect line numbers.

AUTHOR
======

  * Timo Paulssen

Source can be located at: https://github.com/raku-community-modules/App-MoarVM-Debug . Comments and Pull Requests are welcome.

COPYRIGHT AND LICENSE
=====================

Copyright 2017 - 2020 Edument AB

Copyright 2024 The Raku Community

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

