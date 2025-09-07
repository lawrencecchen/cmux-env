use anyhow::{anyhow, Context, Result};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;

// ---------------- Path helpers ----------------

pub fn runtime_dir() -> PathBuf {
    if let Ok(p) = std::env::var("XDG_RUNTIME_DIR") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    PathBuf::from("/tmp")
}

pub fn socket_path() -> PathBuf {
    let base = runtime_dir().join("cmux-envd");
    base.join("envd.sock")
}

fn ensure_socket_dir() -> Result<PathBuf> {
    let dir = runtime_dir().join("cmux-envd");
    fs::create_dir_all(&dir).with_context(|| format!("creating dir {}", dir.display()))?;
    Ok(dir)
}

// ---------------- Protocol ----------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ShellKind {
    Bash,
    Zsh,
    Fish,
}

impl ShellKind {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "bash" => Some(ShellKind::Bash),
            "zsh" => Some(ShellKind::Zsh),
            "fish" => Some(ShellKind::Fish),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(tag = "type", content = "path")]
pub enum Scope {
    Global,
    Dir(PathBuf),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Request {
    Ping,
    Status,
    Set { key: String, value: String, scope: Scope },
    Unset { key: String, scope: Scope },
    Get { key: String, pwd: Option<PathBuf> },
    List { pwd: Option<PathBuf> },
    Load { entries: Vec<(String, String)>, scope: Scope },
    Export { shell: ShellKind, since: u64, pwd: PathBuf },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Response {
    Pong,
    Status { generation: u64, globals: usize, scopes: usize },
    Ok,
    Value { value: Option<String> },
    Map { entries: HashMap<String, String> },
    Export { script: String, new_generation: u64 },
    Error { message: String },
}

fn read_json(stream: &mut UnixStream) -> Result<Request> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.is_empty() {
        return Err(anyhow!("empty request"));
    }
    let req: Request = serde_json::from_str(&line).context("parse request")?;
    Ok(req)
}

fn write_json(stream: &mut UnixStream, resp: &Response) -> Result<()> {
    let s = serde_json::to_string(resp)?;
    stream.write_all(s.as_bytes())?;
    stream.write_all(b"\n")?;
    Ok(())
}

// --------------- State ----------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangeEvent {
    pub generation: u64,
    pub key: String,
    pub scope: Scope,
}

#[derive(Debug, Default)]
pub struct State {
    pub generation: u64,
    pub globals: HashMap<String, String>,
    pub scoped: HashMap<PathBuf, HashMap<String, String>>, // Dir -> (key -> value)
    pub history: Vec<ChangeEvent>,
}

impl State {
    pub fn set(&mut self, scope: Scope, key: String, value: String) -> bool {
        match scope {
            Scope::Global => {
                let changed = self.globals.get(&key) != Some(&value);
                if changed {
                    self.globals.insert(key.clone(), value);
                    self.bump(key, Scope::Global);
                }
                changed
            }
            Scope::Dir(path) => {
                let path_c = canon(path);
                let entry = self.scoped.entry(path_c.clone()).or_default();
                let changed = entry.get(&key) != Some(&value);
                if changed {
                    entry.insert(key.clone(), value);
                    self.bump(key, Scope::Dir(path_c));
                }
                changed
            }
        }
    }

    pub fn unset(&mut self, scope: Scope, key: String) -> bool {
        match scope {
            Scope::Global => {
                let existed = self.globals.remove(&key).is_some();
                if existed {
                    self.bump(key, Scope::Global);
                }
                existed
            }
            Scope::Dir(path) => {
                let path = canon(path);
                if let Some(map) = self.scoped.get_mut(&path) {
                    let existed = map.remove(&key).is_some();
                    if existed {
                        self.bump(key, Scope::Dir(path));
                    }
                    existed
                } else {
                    false
                }
            }
        }
    }

    fn bump(&mut self, key: String, scope: Scope) {
        self.generation += 1;
        // normalize dir scope to canonical form
        let scope = match scope {
            Scope::Dir(p) => Scope::Dir(canon(p)),
            x => x,
        };
        self.history.push(ChangeEvent { generation: self.generation, key, scope });
    }

    pub fn load(&mut self, scope: Scope, entries: Vec<(String, String)>) {
        for (k, v) in entries {
            self.set(scope.clone(), k, v);
        }
    }

    pub fn effective_for_pwd(&self, pwd: &Path) -> HashMap<String, String> {
        let mut map = self.globals.clone();
        if let Some((_, overlay)) = self.best_scope_for_pwd(pwd) {
            for (k, v) in overlay.iter() {
                map.insert(k.clone(), v.clone());
            }
        }
        map
    }

    pub fn get_effective(&self, key: &str, pwd: &Path) -> Option<String> {
        if let Some((_, overlay)) = self.best_scope_for_pwd(pwd) {
            if let Some(v) = overlay.get(key) {
                return Some(v.clone());
            }
        }
        self.globals.get(key).cloned()
    }

    // Returns best matching directory scope (deepest ancestor) and its map
    fn best_scope_for_pwd(&self, pwd: &Path) -> Option<(PathBuf, &HashMap<String, String>)> {
        let pwd = canon(pwd);
        let mut best: Option<(PathBuf, &HashMap<String, String>)> = None;
        for (dir, vars) in &self.scoped {
            if is_ancestor(dir, &pwd) {
                match &best {
                    None => best = Some((dir.clone(), vars)),
                    Some((bdir, _)) => {
                        if dir.components().count() > bdir.components().count() {
                            best = Some((dir.clone(), vars));
                        }
                    }
                }
            }
        }
        best
    }

    pub fn export_since(&self, shell: ShellKind, since: u64, pwd: &Path) -> (String, u64) {
        let new_gen = self.generation;
        let mut changed_keys: HashSet<String> = HashSet::new();
        let pwd_c = canon(pwd);
        for ev in self.history.iter().filter(|e| e.generation > since) {
            match &ev.scope {
                Scope::Global => {
                    changed_keys.insert(ev.key.clone());
                }
                Scope::Dir(dir) => {
                    if is_ancestor(dir, &pwd_c) {
                        changed_keys.insert(ev.key.clone());
                    }
                }
            }
        }

        // For each changed key, compute current effective value for pwd
        let mut actions: Vec<(String, Option<String>)> = Vec::new();
        for key in changed_keys.into_iter() {
            let val = self.get_effective(&key, &pwd_c);
            actions.push((key, val));
        }
        actions.sort_by(|a, b| a.0.cmp(&b.0));
        let script = render_script(shell, &actions, new_gen);
        (script, new_gen)
    }
}

fn is_ancestor(a: &Path, b: &Path) -> bool {
    let a = canon(a);
    let b = canon(b);
    b.starts_with(a)
}

fn canon<P: AsRef<Path>>(p: P) -> PathBuf {
    let p = p.as_ref();
    match p.canonicalize() {
        Ok(c) => c,
        Err(_) => p.to_path_buf(),
    }
}

// --------------- Scripting ---------------

fn sh_single_quote(val: &str) -> String {
    // Replace ' with '\'' pattern
    let mut out = String::with_capacity(val.len() + 2);
    out.push('\'');
    for ch in val.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

fn render_script(shell: ShellKind, actions: &[(String, Option<String>)], new_gen: u64) -> String {
    let mut out = String::new();
    match shell {
        ShellKind::Bash | ShellKind::Zsh => {
            for (k, v) in actions {
                if is_valid_key(k) {
                    match v {
                        Some(val) => {
                            out.push_str(&format!("export {}={}\n", k, sh_single_quote(val)));
                        }
                        None => {
                            out.push_str(&format!("unset -v {}\n", k));
                        }
                    }
                }
            }
            out.push_str(&format!("export ENVCTL_GEN={}\n", new_gen));
        }
        ShellKind::Fish => {
            for (k, v) in actions {
                if is_valid_key(k) {
                    match v {
                        Some(val) => out.push_str(&format!("set -x {} {}\n", k, sh_single_quote(val))),
                        None => out.push_str(&format!("set -e {}\n", k)),
                    }
                }
            }
            out.push_str(&format!("set -x ENVCTL_GEN {}\n", new_gen));
        }
    }
    out
}

fn is_valid_key(k: &str) -> bool {
    let first = k.chars().next();
    if first.map(|c| c == '_' || c.is_ascii_alphabetic()).unwrap_or(false) == false {
        return false;
    }
    k.chars().all(|c| c == '_' || c.is_ascii_alphanumeric())
}

// --------------- Server plumbing ---------------

pub fn run_server() -> Result<()> {
    ensure_socket_dir()?;
    let sock = socket_path();
    if sock.exists() {
        let _ = fs::remove_file(&sock);
    }
    let listener = UnixListener::bind(&sock).with_context(|| format!("bind {}", sock.display()))?;
    let state = Arc::new(Mutex::new(State::default()));

    loop {
        let (mut stream, _addr) = listener.accept()?;
        let state = state.clone();
        std::thread::spawn(move || {
            let resp = match read_json(&mut stream) {
                Ok(req) => handle_request(req, &state),
                Err(e) => Response::Error { message: format!("read error: {}", e) },
            };
            let _ = write_json(&mut stream, &resp);
        });
    }
}

fn resolve_pwd(pwd: Option<PathBuf>) -> PathBuf {
    pwd.unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

fn handle_request(req: Request, state: &Arc<Mutex<State>>) -> Response {
    let mut st = state.lock();
    match req {
        Request::Ping => Response::Pong,
        Request::Status => Response::Status { generation: st.generation, globals: st.globals.len(), scopes: st.scoped.len() },
        Request::Set { key, value, scope } => {
            st.set(scope, key, value);
            Response::Ok
        }
        Request::Unset { key, scope } => {
            st.unset(scope, key);
            Response::Ok
        }
        Request::Get { key, pwd } => {
            let pwd = resolve_pwd(pwd);
            let v = st.get_effective(&key, &pwd);
            Response::Value { value: v }
        }
        Request::List { pwd } => {
            let pwd = resolve_pwd(pwd);
            let entries = st.effective_for_pwd(&pwd);
            Response::Map { entries }
        }
        Request::Load { entries, scope } => {
            st.load(scope, entries);
            Response::Ok
        }
        Request::Export { shell, since, pwd } => {
            let (script, new_generation) = st.export_since(shell, since, &pwd);
            Response::Export { script, new_generation }
        }
    }
}

// --------------- Client plumbing ---------------

pub fn client_send(req: &Request) -> Result<Response> {
    let mut stream = UnixStream::connect(socket_path())
        .with_context(|| format!("connect {}", socket_path().display()))?;
    let s = serde_json::to_string(req)?;
    stream.write_all(s.as_bytes())?;
    stream.write_all(b"\n")?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.is_empty() {
        return Err(anyhow!("empty response"));
    }
    let resp: Response = serde_json::from_str(&line).context("parse response")?;
    Ok(resp)
}

pub fn parse_dotenv<R: Read>(mut r: R) -> Result<Vec<(String, String)>> {
    let mut s = String::new();
    r.read_to_string(&mut s)?;
    let mut out = Vec::new();
    for (idx, line) in s.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let line = line.strip_prefix("export ").unwrap_or(line);
        if let Some(eq) = line.find('=') {
            let (k, v) = line.split_at(eq);
            let k = k.trim().to_string();
            let v = v[1..].trim().to_string();
            let v = strip_quotes(&v);
            if !is_valid_key(&k) {
                return Err(anyhow!("invalid key at line {}: {}", idx + 1, k));
            }
            out.push((k, v));
        } else {
            return Err(anyhow!("invalid line {}: {}", idx + 1, line));
        }
    }
    Ok(out)
}

fn strip_quotes(s: &str) -> String {
    if (s.starts_with('\"') && s.ends_with('\"')) || (s.starts_with('\'') && s.ends_with('\'')) {
        s[1..s.len() - 1].to_string()
    } else {
        s.to_string()
    }
}
