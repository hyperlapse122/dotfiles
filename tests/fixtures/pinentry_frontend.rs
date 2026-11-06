//! A native, hardware-free frontend. Only non-secret control state reaches disk.
use std::{
    fs,
    io::{self, BufRead, Write},
};

fn main() -> io::Result<()> {
    let root = std::env::current_exe()?.parent().unwrap().to_owned();
    println!("OK disposable frontend ready");
    io::stdout().flush()?;
    for line in io::stdin().lock().lines() {
        let line = line?;
        match line.as_str() {
            "GETPIN" => {
                let count = fs::read_to_string(root.join("frontend-count"))?
                    .parse::<u32>()
                    .map_err(io::Error::other)?
                    + 1;
                fs::write(root.join("frontend-count"), count.to_string())?;
                if fs::read_to_string(root.join("frontend-mode"))? == "cancel" {
                    println!("ERR 83886179 Operation cancelled");
                } else {
                    println!("D synthetic-pin-{count:08}\nOK frontend input");
                }
            }
            "CONFIRM" => println!("OK frontend confirmation"),
            "MESSAGE" => println!("OK frontend message"),
            _ => println!("OK"),
        }
        io::stdout().flush()?;
        if line == "BYE" {
            break;
        }
    }
    Ok(())
}
