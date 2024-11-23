use MoarVM::Remote;
use App::MoarVM::Debug::Formatter;
use App::MoarVM::Debug::Breakpoints;
use JSON::Fast;

my str $spaces     = " "  x 80;
my str $backspaces = "\b" x 80;

#- global variables ------------------------------------------------------------

my $remote;
my $default-thread;
my @user-threads;
my %breakpoints;
my %abbreviated;
my %reverse-abbreviated;
my $abbreviate-length;

my @last-command-handles;
my $last-command;

my $events-lock := Lock.new;
my %interesting-events;

my constant %name-map =
 bytecode_file => "Bytecode file",
 file          => "File",
 line          => "Line",
 name          => "Routine name",
 type          => "Frame type"
;

#- helper subs -----------------------------------------------------------------

multi sub table-print(Pair:D $pair) {
    table-print ($pair,)
}
multi sub table-print(@chunks) {
    MoarVM::Remote::CLI::Formatter::print-table(
      @chunks, :%abbreviated, :%reverse-abbreviated, :$abbreviate-length
    );
}

sub boring-metadata($_, $v) {
    .starts-with("p6opaque")
      && (.starts-with("p6opaque_unbox") || .ends-with("s_delegate"))
      ?? $v == -1
      !! False
}

sub remote(str $action, &code-to-remote, :$dont-await) {
    my int $width = $action.chars;
    print $action;

    my $result := $dont-await
      ?? code-to-remote()
      !! await code-to-remote();

    print $backspaces.substr(0,$width);
    print     $spaces.substr(0,$width);
    print $backspaces.substr(0,$width);

    $result
}

sub thread($thread) {
    with $thread.defined ?? $thread.Int !! $default-thread {
        $_
    }
    else {
        say "Must specify a thread, or do an 'assume thread N' first";
        Any
    }
}

#- the "help" logic ------------------------------------------------------------

multi sub help(--> Nil) {
    say qq:to/CMDS/;
Supported commands:

&bold("dump") [thread number]
  Print a stacktrace for the given thread.
  Synonyms: &bold("bt")

&bold("frame") frame [thread number]
  Print single frame information.
  Synonyms: &bold("fr")

&bold("suspend") [thread number]
  Suspend a thread, or all thread if no thread number is passed.

&bold("resume")  [thread number]
  Resume a thread, or all thread if no thread number is passed.

&bold("step") into [thread number]
  Continue running code on the given thread until a different source
  line is reached.

&bold("step over") [thread number]
  Continue running code on the given thread until a different source
  line in the same frame, or the current frame is left.

&bold("step out") [handle (MVMContext)] [thread number]
  Continue running code on the given thread until the given
  frame is reached. To use this for stepping out, get a
  ctxhandle for the frame you consider "out".

&bold("tl")
  Output a list of all threads and their status.
  Synonyms: &bold("threads")

&bold("ctxhandle") framenumber [thread number]
  Retrieve a handle for a frame (MVMContext) on the thread's stack.
  Synonyms: &bold("stackframe")

&bold("caller") [handle (MVMContext)]
  Retrieve a handle for a frame's caller frame (MVMContext)

&bold("outer") [handle (MVMContext)]
  Retrieve a handle for a frame's outer frame (MVMContext)

&bold("coderef") frame number [thread number]
  Retrieve a handle for the code object (MVMCode) for a frame on a thread's stack.

&bold("lexicals") [handle (MVMContext)]
  Retrieve a list of lexicals and handlers for any object lexicals for a given frame.
  Synonyms: &bold("lex")

&bold("all lexicals") [thread number]
  Retrieve a list of lexicals &bold("all") frames of a given thread.
  Synonyms: &bold("lex")

&bold("metadata") [handle (MVMObject)]
  Retrieve a bunch of metadata about an object.
  Synonyms: &bold("meta")

&bold("attributes") [handle (MVMObject)]
  Retrieve a list of all attributes an object has, along with handles for any object values.
  Synonyms: &bold("attrs")

&bold("positionals") [handle (MVMObject)]
  Retrieve the contents of an object that has positional properties, like an array.
  Synonyms: &bold("pos")

&bold("associatives") [handle (MVMObject)]
  Retrieve the contents of an object that has associative properties, like a hash.
  Synonyms: &bold("assoc")

&bold("release") [handle handle ...]
  Releases handles, so the corresponding objects can be garbage collected.

&bold("release") all [keep [handle handle ...]]
  Release all handles allocated by the previous command, optionally keeping
  the specified handles for further use.

&bold("[breakpoint|bp]") "[file path]" [line number] [suspend]? [stacktrace]?
  Sets a breakpoint for a given filename and line number.
  If suspend is 1, execution of the thread that hit it will stop.
  If stacktrace is 1, every hit will send a stack trace along with it.

&bold("breakpoints")
  Print all breakpoints.
  Synonyms: &bold("bpl")

&bold("clearbp") [id] | "[file path]" [line number]
  Clear any breakpoints for a given ID or filename and line number.

&bold("assume thread") [thread number]
  If you don't pass a thread number in future commands, this one will be used.

&bold("assume no thread")
  Resets the thread selection.

&bold("abbrev") [abbrev-key]
  Display the full output for any abbreviated field.

&bold("abbrev length") length
  Change the default witdth of columns in printed tables.

&bold("debug") [on|off]
  Turns debugging information on or off, or display whether it's on or off.

&bold("color") [on|off]
  Turn ANSI Colors on or of or display whether it's on or off.
CMDS
}

#- action handling subs --------------------------------------------------------

sub abbrev(Str() $key --> Nil) {
    say my $header = "Contents of entry $key:";
    say "=" x $header.chars;
    say %abbreviated{$key};
    my $footer = "End of Contents of entry $key";
    say "=" x $footer.chars;
    say $footer;
}

sub abbrev-length(Int() $length --> Nil) {
    $abbreviate-length = $length;
    say "Abbreviation length is set to $length";
}

# convenience: grab all lexicals on the stack
sub all-lexicals($id --> Nil) {
    with thread($id) -> $thread {
        my $forget-promise;

        my @chunks = remote "fetching all lexicals", {
            my @allframes = (await $remote.dump($thread)).map: {
                (.<name> // "") eq '<unit-outer>'
                  ?? (last)
                  !! $_
            }
            my $framecount = +@allframes;
            my @frame-handles;
            my @all-lexicals;

            @last-command-handles = Empty;

            for (^$framecount).reverse {
                my $handle = await $remote.context-handle($thread, $_);
                my $lexicals = (await $remote.lexicals($handle));

                @last-command-handles.push($handle) if $handle;

                @frame-handles[$_] = $handle;
                @all-lexicals[$_] = $lexicals;
            };

            # Check if any handles want to be replaced by an earlier handle,
            # if they refer to the same thing.

            my @all-handles = |@frame-handles;
            @all-handles.append($_.>>.<handle>.values.grep(*.so)) for @all-lexicals;

            my (@classes, %to-replace, @to-forget);
            try {
                @classes = await $remote.equivalences(@all-handles);
                %to-replace = classes-to-renaming(@classes);
                @to-forget = %to-replace.keys;
            }

            $forget-promise = $remote.release-handles(@to-forget) if @to-forget;

            (^$framecount).reverse.map: {
                my $handle   := @frame-handles[$_];
                my $lexicals := @all-lexicals[$_];

                my $framedetails := "$_<name> ($_<file>:$(colored($_<line>, "bold")))" given @allframes[$_];

                "Frame $_ - $framedetails - handle: &bold($handle)"
                  => format-lexicals-for-frame($lexicals,
                    handles-seen    => @last-command-handles,
                    handle-renaming => %to-replace
                  )
            }
        }, :dont-await;

        table-print(@chunks);

        await $_ with $forget-promise;

        say "";
        say "call 'release all' to free these &bold(@last-command-handles.elems()) handles";
    }
}

sub associatives(Int() $handle --> Nil) {
    my $result := remote
      "fetching associaitives for handle $handle",
      { $remote.object-associatives($handle) }

    my @associatives is List = gather {
        if $result<kind> eq "obj" {
            @last-command-handles = Empty;
            for $result<contents>.list {
                my @attributes = format-attributes(.value);
                @last-command-handles.push(.value<handle>) if .value<handle>;
                take [&bold(.value<handle>), .key, .value<type>, @attributes.join(", ")];
            }
        }
        else {
            take ["NYI"];
        }
    }
    table-print "Associatives in handle &bold($handle)" => @associatives;
}

multi sub assume-thread(--> Nil) {
    say "Not going to assume any thread for further commands";
    $default-thread = Any;
}
multi sub assume-thread($thread --> Nil) {
    with thread($thread) {
        say "Assuming thread $_ as default for further commands";
        $default-thread = $_;
    }
}

sub attributes(Int() $handle --> Nil) {
    my $result := remote
      "fetching attribute info for $handle",
      { $remote.attributes($handle) }

    say "Attributes for handle &bold($handle)";
    table-print $result.categorize(*.<class>).map: {
        "From class $_.key()"
          => .value.map({
                my str $attributes = format-attributes($_).join(", ");
                my str $type       = .<kind>;
                $type = .<type> if $type eq "obj";

                (bold(.<handle> // ""), $type, .<name>, $attributes)
             }).List
    }
}

sub backtrace($id --> Nil) {
    with thread($id) -> $thread {
        my @frames := remote
          "Fetching backtrace of thread $thread",
          { $remote.dump($thread) }

        table-print
          "Stack trace of thread &bold($thread)" => format-backtrace(@frames);
    }
}

sub breakpoint(
  Str() $file, Int() $line, Bool() $suspend = False, Bool() $stacktrace = False
--> Nil) {
    if %breakpoints.pairs.first: { .value<file> eq $file and .value<line> eq $line } -> $b {
        say "A breakpoint for this file and line (suspend={{$b.value<suspend>}} stacktrace={$b.value<suspend>}) already exists.";
        say 'Replace it with this new one? (y/n)';        
        while my $answer = prompt('> ') {
            if    $answer eq 'y' { clearbp $b.key; last }
            elsif $answer eq 'n' { return }
            else                 { say "It's a y/n answer, but given $answer" }
        }
    }

    my $result := remote
      "setting breakpoint",
      { $remote.breakpoint($file, $line, :$suspend, :$stacktrace) }
    state $id = 1;
    %breakpoints{$id++} = %(:$file, :$line, :$suspend, :$stacktrace);

    output-breakpoint-notifications($file, $result<line>, $_)
      with $result<notifications>;
}

sub breakpoint-list {
    table-print "Breakpoints" => (('id', 'file', 'line', 'suspend', 'stacktrace'), |%breakpoints.sort(*.key).map({
        ($_.key, $_.value<file line suspend stacktrace>)>>.List.flat if defined $_.value
    }));
}

sub caller(Int() $handle --> Nil) {
    my $result := remote
      "fetching caller context for handle $handle",
      { $remote.caller-context-handle($handle) }

    say $result.&to-json(:pretty);
}

multi sub clearbp(Int() $id --> Nil) {
    say "Breakpoint with this ID ($id) does not exist" and return unless defined %breakpoints{$id};
    my ($file, $line) = %breakpoints{$id}<file line>;
    clearbp $file, $line, $id;
}

multi sub clearbp(Str() $file, Int() $line, Int() $id? is copy --> Nil) {
    $id //= %breakpoints.pairs.first({ .value<file> eq $file and .value<line> eq $line }).key
        or say "No breakpoint like that ($file:$line) exists" and return;
    %breakpoints{$id}:delete;

    my $result := remote
      "clearing breakpoint for $file:$line",
      { $remote.clear-breakpoints($file, $line) }
    
    say "Deleted breakpoint for $file:$line with ID $id";
}

sub coderef(Int() $frame, $id) {
    with thread($id) -> $thread {
        my $result = remote
          "fetching coderef handle for frame $frame",
          { $remote.coderef-handle($thread, $frame) }
        say $result.&to-json(:pretty);
    }
}

sub color($state --> Nil) {
    with $state {
        wants-color() = $state eq "on";
        say "Colored output is now &bold($state)";
    }
    else {
        say "Colored output is currently &bold(wants-color() ?? "on" !! "off")";
        say "(but color is not available; install Terminal::ANSIColor maybe?)"
          unless has-color;
    }
}

sub connect($port) {
    my $result := remote
      "connecting to MoarVM remote on localhost port $port",
      { MoarVM::Remote.connect($port) }

    say "Connected on localhost port $port";
    $result
}

sub ctxhandle(Int() $frame, $id --> Nil) {
    with thread($id) -> $thread {
        my $result := remote
          "fetching context handle for frame $frame in thread $thread",
          { $remote.context-handle($thread, $frame)}

        say $result.&to-json(:pretty);
    }
}

sub debug($state --> Nil) {
    with $state {
        $remote.debug = $state eq "on";
        say "Debug output is now &bold($state)";
    }
    else {
        say "Debug currently &bold($remote.debug ?? "on" !! "off")";
    }
}

sub decont(Int() $handle, $id --> Nil) {
    with thread($id) -> $thread {
        my $result := remote
          "fetching handle for decontainerized value of handle $handle",
          { $remote.decontainerize($thread, $handle) }
        say $result.&to-json(:pretty);
    }
}

sub frame(Int() $frame, $id --> Nil) {
    with thread($id) -> $thread {
        my @frames := remote "fetching backtrace", { $remote.dump($thread) }

        if @frames[$frame] -> %frame {
            # ${:bytecode_file("/Users/vrurg/src/Perl6/BO-Trading/lib/.precomp/F4586E0D974A9D7EE7CD910A6978305B9EBD4E57/C4/C4B0B4FF604F072E60052CB30401D1B21830E56D"), :file("/Users/vrurg/src/Perl6/BO-Trading/lib/BO-Trading/Scraper.pm6 (BO-Trading::Scraper)"), :line(148), :name(""), :type("Block")}

            temp $abbreviate-length *= 2;
            table-print
              "Frame &bold($frame) of thread &bold($thread)"
                => <bytecode_file file line name type>.map({
                  if %frame{$_} {
                      bold(%name-map{$_}), %frame{$_}
                  }
              }).List;
        }
        else {
            say "No frame $frame in thread $thread (0 .. @frames.end())";
        }
    }
}

sub hllsym($name, $key --> Nil) {
    with $name {
        with $key {
            my $result := remote
              "fetching HLL sym '$key' in '$name'",
              { $remote.get-hll-sym($name.Str, $key.Str) }
            say "handle: ", $result;
        }
        else {
            my $result := remote
              "fetching names for HLL sym '$name'",
              { $remote.get-hll-sym-keys($name.Str) }
            say "Keys in HLL '$name': $result.sort(*.fc)";
        }
    }
    else {
        my $result := remote
          "fetching HLL sym keys",
          { $remote.get-available-hlls }
        say "Available HLLs: $result.sort(*.fc)";
    }
}

sub invoke(Int() $handle, *@raw --> Nil) {
    my $thread = $default-thread;

    my @arguments = $@raw.map({
        .[0] eq "i:"        ?? ("int", try +.[1]) !!
        .[0] eq        "o:" ?? ("obj", try +.[1]) !!
        .[0] eq "s:" ?? ("str", .[1].starts-with('"') && .[1].ends-with('"') ?? .[1].substr(1, *-1) !! .[1].Str) !!
        .[0] eq "so:" ?? ("str", .[1].Int) !!
        .[0] eq "n:" ?? ("num", .[1].Str.Num) !!
        die "can't figure out this argument: $_.Str()"
    });
    my str $s = @arguments.elems == 1 ?? "" !! "s";

    my $promise := remote
      "invoking $handle in thread $thread with @arguments.elems() argument$s",
       { $remote.invoke($thread, $handle, @arguments) }

    $promise.then: {
        table-print
          "Invocation result of &bold($handle) with &bold(+@arguments) arguments"
            => .result
               .grep(*.key eq none(<type id>))
               .sort(*.value.^name)
               .map(*.kv)
               .List;
    }
}

sub is-suspended(--> Nil) {
    say (remote "checking", { $remote.is-execution-suspended })
      ?? "No user threads are running"
      !! "All user threads are running";
}

sub lexicals(Int() $handle --> Nil) {
    @last-command-handles = Empty;

    my $result := remote
      "fetching lexicals of $handle",
      { $remote.lexicals($handle) }

    table-print
      "Lexicals of handle &bold($handle)"
        => format-lexicals-for-frame($result, handles-seen => @last-command-handles);
}

sub metadata(Int() $handle --> Nil) {
    my $result := remote
      "fetching metadata of handle $handle",
      { $remote.object-metadata($handle) }

    table-print
      "Metadata of handle &bold($handle)"
        => (gather {
          my @features =
              flat "positional"  xx ?$result<pos_features>,
                   "associative" xx ?$result<ass_features>,
                   "attributes"  xx ?$result<attr_features>;
          take ["Features", @features.join(", ") || "none"];
          take ["Size", ($result<size> // 0) ~ " + unmanaged: " ~ ($result<unmanaged_size> // 0)];
          for $result.list.sort(*.key) {
              next if .key eq any <pos_features ass_features attr_features size unmanaged_size>;
              next if boring-metadata(.key, .value);
              if .value ~~ Positional {
                  take [.key, .value.join(", ")];
              } else {
                  take [.key, .value // "-"];
              }
          }
      }).List;
}

sub outer(Int() $handle --> Nil) {
    my $result := remote
      "fetching outer context for handle $handle",
      { $remote.outer-context-handle($handle) }

    say $result.&to-json(:pretty);
}

sub positionals(Int() $handle --> Nil) {
    my $result := remote
      "fetching positional elements for handle $handle",
      { $remote.object-positionals($handle) }

    my $cnt = $result<start>;
    if $result<kind> eq "obj" {
        @last-command-handles = Empty;
        my @elements is List = do for $result<contents>.list {
            my @attributes = format-attributes($_);
            @last-command-handles.push($_<handle>) if $_<handle>;
            [$cnt++, bold($_<handle>), $_<type>, @attributes.join(", ")]
        }
        table-print "Positionals in handle &bold($handle)" => @elements;
    }
    elsif $result<kind> eq "callsite" {
        my $cnt = 0;
        my $name-idx = 0;
        dd $result<contents>.list;
        dd $result<callsite><callsite_flags>.list;
        my @elements is List = do for $result<contents>.list Z $result<callsite><callsite_flags>.list -> ($_, $flags) {
            my @attributes;
            push @attributes, "literal" if "literal" (elem) $flags;
            push @attributes, "named " ~ ($result<callsite><arg_names>[$name-idx++]) if "named" (elem) $flags;

            if $flags[0] eq "obj" {
                @attributes.append(format-attributes($_));
                [$cnt++, bold($_<handle>), $_<type>, "", @attributes.join(", ")];
            }
            elsif $flags[0] eq "str" {
                [$cnt++, "", "Str", $_.raku, @attributes.join(", ")];
            }
            elsif $flags[0] eq "int" | "uint" {
                [$cnt++, "", $flags[0], $_, @attributes.join(", ")];
            }
            else {
                [$cnt++, "", colored("?", "red"), $_.raku, @attributes.join(", ")];
            }
        }

        my $cscnt = 0;
        my $csname-idx = 0;
        my @callsite is List = do for $result<callsite><callsite_flags>.list {
            my @attributes;
            push @attributes, "literal" if "literal" (elem) $_;
            push @attributes, "named " ~ ($result<callsite><arg_names>[$csname-idx++]) if "named" (elem) $_;

            [$cscnt++, "", $_[0], "", @attributes.join(", ")]
        }

        table-print ["Callsite (arguments shape)" => @callsite, "Positionals in handle &bold($handle)" => @elements];
    }
    else {
        my @elements is List = do for $result<contents>.list {
            [$cnt++, $_]
        }
        table-print "Positionals in handle &bold($handle)" => @elements;
    }
}

sub release-handles(*@handles --> Nil) {
    my int $elems = @handles.elems;
    my str $s = $elems == 1 ?? "" !! "s";
    remote
      "releasing $elems handle$s",
      { $remote.release-handles(@handles.map(*.Int)) }
    say "Released $elems handle$s";
}

sub release-all-handles(*@keep --> Nil) {
    my $to-free := @last-command-handles (-) @keep.map(*.Int);
    my int $elems = $to-free.elems;
    my str $s = $elems == 1 ?? "" !! "s";
    remote
      "releasing $elems handle$s",
      { $remote.release-handles($to-free.keys) }

    say @keep
      ?? "Released $elems handle$s, keeping @keep.elems()"
      !! "Released $elems handle$s";

    @last-command-handles = Empty;
}

sub resume($thread is copy --> Nil) {
    $thread = $thread.defined ?? $thread.Int !! Whatever;
    remote "resuming", { $remote.resume($thread) }

    say $thread
      ?? "Resumed thread $thread"
      !! "Resumed all user threads";
}

sub step($type is copy, $id) {
    with thread($id) -> $thread {
        $type = $type ?? $type.Str !! "into";
        my %named = $type => True;

        my Promise $step-finished .= new;

        $events-lock.protect: {
            my $result := remote
              "stepping $type",
              { $remote.step($thread, |%named) }

            my $before = now;

            %interesting-events{$result} = -> $event {
                my $timetext = now >= $before + 3
                  ?? " last requested $((now - $before).fmt("%6.3f")) ago"
                  !! "";
                table-print
                  "Stack trace of thread &bold($event<thread>) after step $type$timetext"
                    => format-backtrace($event<frames>);
                $step-finished.keep();
                "delete";
            }
        }

        # if the step finishes quite quickly, we wait a tiny moment before
        # spitting out the prompt again.
        # If you step into something that blocks, like sleep or IO or whatever,
        # we don't want to slow the user down.
        #
        # The brief wait also makes it possible to just hold down enter
        # without the repl somehow getting stuck.
        react {
          whenever $step-finished {
            last;
          }
          whenever Promise.in(0.07) {
            last;
          }
        }
    }
}

sub repeating-step($id, $codetext) {
    with thread($id) -> $thread {
        use MONKEY-SEE-NO-EVAL;
        my $steppercode = EVAL '-> $_ ' ~ $codetext;

        my Supplier $step-request-supplier .= new;
        sub one-more-step() {
            $step-request-supplier.emit(++$);
            CATCH {
                say "caught in one-more-step:";
                .say;
                $!.say;
            }
        }

        say "Going to step thread $thread until the given code returns True";
        say "Press ctrl-c to interrupt.";
        say "";

        react {
            whenever $step-request-supplier.Supply {
                my Promise $step-finished .= new;
                my $before;

                $events-lock.protect: {
                    my $result := await $remote.step($thread, :into);

                    $before = now;

                    %interesting-events{$result} = -> $event {
                        $step-finished.keep($event);
                        "delete";
                    }
                }

                my $last-step-finish-tap = do whenever $step-finished -> $event {
                    my &*print-stacktrace = {
                        # Since we are outputting a running "x steps done"
                        # where we keep the line around with backspaces, we
                        # should put empty lines before and after any output
                        say "";
                        say "";
                        table-print
                            "Stack trace of thread &bold($event<thread>) after automatic step"
                                => format-backtrace($event<frames>);
                        say "";
                        say "";
                    }
                    my $*before = $before;
                    my $*remote = $remote;

                    if $steppercode($event) {
                        say "User-provided stepper function indicated stop.";
                        $step-request-supplier.done;
                    }
                    else {
                        one-more-step;
                    }
                }

                # when the sigint handler calls .done on the
                # step request supply, this LAST block is called.
                # We have access to the last step finish tap as well
                # as the last in-use step-finished promise.
                LAST {
                    # After the user stopped the stepping, don't run the
                    # stepper code any more.
                    $last-step-finish-tap.close;

                    my $start-waiting = now;

                    my $suggestion-timeout-tap = do whenever Promise.in(2) {
                        say "";
                        say "Step is not finishing quickly. Press ctrl-c a second time to stop waiting";
                        say "";
                    }
                    whenever $step-finished {
                        $suggestion-timeout-tap.close;
                        done;
                    }
                    # Let's also output a notification when the step has
                    # finished even if we have aborted this react block.
                    $step-finished.then({
                        if $start-waiting before now - 2 {
                            say "Step started in a step-until { now - $start-waiting }s ago finished.";
                        }
                    });
                }
            }
            whenever $step-request-supplier.Supply -> $n {
                FIRST {
                    say "Starting to step ...";
                }
                print $backspaces.substr(0, 20);
                print "done $n steps ...";
            }
            whenever signal(SIGINT) {
                say "";
                say "Sigint caught. Will not request any more steps ...";
                say "";
                $step-request-supplier.done;
                # We can notify the user about the ability to press ctrl-c a
                # second time if we're not done immediately.
                # We don't immediately just exit the whole react block because
                # leaving a step "hanging" could be undesirable.
                whenever signal(SIGINT) {
                    say "";
                    say "Sigint caught a second time. Leaving the stepping process ...";
                    say "";
                    done;
                }
                last;
            }
            $step-request-supplier.emit(0);
        }
    }
}

sub suspend($thread is copy --> Nil) {
    $thread = $thread.defined ?? $thread.Int !! Whatever;
    remote "suspending", { $remote.suspend($thread) }

    say $thread
      ?? "Suspended thread $thread"
      !! "Suspended all user threads";
}

sub thread-list(--> Nil) {
    my $result := remote "fetching thread list", { $remote.threads-list }
    my @threads =
      <<thread suspended "native id" "num locks" "app lifetime?" name>>.item;
    for $result.sort(*.<thread>) {
        @threads.push: (
          bold(.<thread>), .<suspended>, .<native_id>.fmt("0x%x"),
          .<num_locks>, .<app_lifetime>, (.<name> // "")
        );
    }
    table-print "Threads" => @threads;
}

#- input handling --------------------------------------------------------------

sub MAIN(
  Int $port = %*ENV<MVM_DEBUG_PORT> // 27434,
  Int :abbreviate-length($abvl) = 70
) is export {
    $abbreviate-length = $abvl;

    say "Welcome to the MoarVM Remote Debugger!";

    unless %*ENV<_>:exists and %*ENV<_>.ends-with: 'rlwrap' {
        say "";
        say "For best results, please run this program inside rlwrap";
    }
    $remote := connect($port);

    $remote.events.tap: {
        $events-lock.protect: {
            my $id := .<id>;
            if %interesting-events{$id}:exists {
                if %interesting-events{$id}($_) eq "delete" {
                    %interesting-events{$id}:delete
                }
            }
            else {
                say "Got event: "; .say
            }
            Nil;
        }
    }

    assume-thread(1);
    until (my $input = prompt("> ")) === Any {
        $_ = $input;
        if m/^$/ {
            $_ = $last-command;
        } else {
            $last-command = $_;
        }
        when /:s execution / {
            is-suspended();
        }
        when /:s sus[p[e[nd?]?]?]? (\d+)? / {
            suspend $0;
        }
        when /:s res[u[m[e?]?]?]? (\d+)? / {
            resume $0;
        }
        when /:s [dump|bt|backtrace] (\d+)? / {
            backtrace $0;
        }
        when /:s [fr|frame] (\d+) (\d+)? / {
            frame $0, $1;
        }
        when / [tl|threads] / {
            thread-list;
        }
        when /:s [ctxhandle|[call|stack]frame] (\d+) (\d+)? / {
            ctxhandle $0, $1;
        }
        when /:s caller (\d+) / {
            caller $0;
        }
        when /:s outer (\d+) / {
            outer $0;
        }
        when /:s coderef (\d+) (\d+)? / {
            coderef $0, $1;
        }
        when /:s all lex[icals]? (\d+)? / {
            all-lexicals $0;
        }
        when /:s lex[icals]? (\d+) / {
            lexicals $0;
        }
        when /:s meta[data]? (\d+) / {
            metadata $0;
        }
        when /:s attr[ibute]?s (\d+) / {
            attributes $0;
        }
        when /:s pos[itionals]? (\d+) / {
            positionals $0;
        }
        when /:s assoc[iatives]? (\d+) / {
            associatives $0;
        }
        when /:s de[cont]? (\d+) (\d+)? / {
            decont $0, $1;
        }
        when /:s clearbp [(\d+) | \"(.*?)\" (\d+)] / {
            $0.Int ?? clearbp $0 !! clearbp $0, $1;
        }
        when /:s [breakpoint|bp][":"|<.ws>]\"(.*?)\" (\d+) (\d?) (\d?) / {
            breakpoint $0, $1, +$2, +$3;
        }
        when /:s [breakpoints|bpl] / {
            breakpoint-list;
        }
        when /:s release[handles]? (\d+)+ % \s+/ {
            release-handles |$0;
        }
        when /:s release all [handles]? [keep (\d+)+ % \s+]?/ {
            release-all-handles |$0;
        }
        when /:s assume thread (\d+)? / {
            assume-thread($0);
        }
        when /:s assume no thread / {
            assume-thread;
        }
        when /:s s[tep]? u[ntil]? (\d+)? ('{' .* '}') / {
            repeating-step $0, $1;
        }
        when /:s s[tep]? (into|over|out)? (\d+)? / {
            step $0, $1;
        }
        when / invoke \s+ (\d+) [\s+ | $] $<arguments>=(( "i:" | "s:" | "n:" | s? "o:" ) ( \" <-["]>* \" | \S+ ) )* % \s+ $ / {
            invoke $0, |$<arguments>;
        }
        when /:s hll[sym]? [$<hllname>=\S+ [$<hllkey>=\S+]? ]? / {
            hllsym $<hllname>, $<hllkey>;
        }
        when /:s abbrev length (\d+) / {
            abbrev-length $0;
        }
        when /:s abbrev (.*) / {
            abbrev $0;
        }
        when /:s debug [(on|off)]?/ {
            debug $0;
        }
        when /:s color [(on|off)]?/ {
            color $0;
        }
        when /:s help / {
            help;
        }
        default {
            say "Don't know what to do with '$_'.\nEnter 'help' for options";
        }
        CATCH {
            default {
                .say;
            }
        }
    }
}

# vim: expandtab shiftwidth=4
