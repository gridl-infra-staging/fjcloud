use std::process::Command;

fn main() {
    let user_input = "ls";
    let cmd_var = "echo";

    Command::new(&user_input);
    Command::new(cmd_var);
    Command::new("/usr/bin/printf");
    std::process::Command::new(user_input);
    std::process::Command::new(format!("{}", "echo"));
    std::process::Command::new("safe");
}
