unit module MoarVM::Remote::CLI::Breakpoints;

use App::MoarVM::Debug::Formatter;

sub output-breakpoint-notifications(Str $file, Int $line, Supply $notifications) is export {
    say "Receiving breakpoint notifications for $file:$line";
    start {
        react whenever $notifications.Supply -> $ev {
            with $ev<frames> -> $frames {
                my @this-backtrace = format-backtrace($frames);

                print-table my @chunks =
                    "Breakpoint on $file:$line hit by thread &bold($ev.<thread>)!"
                        => @this-backtrace;;
            } else {
                say "Breakpoint on $file:$line hit by thread &bold($ev.<thread>)!";
            }
        }
        CATCH {
            say "Breakpoint handler aborted";
            .say;
        }
    };
}

# vim: expandtab shiftwidth=4
