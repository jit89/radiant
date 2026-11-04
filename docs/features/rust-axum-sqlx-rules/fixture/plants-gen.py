"""Generate fixture/plants/*.patch for rust-axum-sqlx-rules: each plant is an
edit to a clean copy of fixture/notes-sqlite (with impl/lib.rs swapped in when
the plant edits the implementation), captured with git diff.
Usage: plants-gen.py FIXTURE_DIR"""
import os
import shutil
import subprocess
import sys
import tempfile

FIX = sys.argv[1]
CRATE = os.path.join(FIX, "notes-sqlite")
IMPL = os.path.join(FIX, "impl", "lib.rs")
OUT = os.path.join(FIX, "plants")
G1, G2, G3 = (f"tests/acceptance/{g}.rs" for g in ("g1", "g2", "g3"))


def append(path, text):
    return ("append", path, text)


def replace(path, old, new):
    return ("replace", path, old, new)


def write(path, text):
    return ("write", path, text)


LISTENER = '''
#[sqlx::test(migrations = "./migrations")]
async fn served_get_is_404(pool: SqlitePool) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(l, router(AppState { pool })).await.unwrap() });
    let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
    s.write_all(b"GET /notes/42 HTTP/1.1\\r\\nHost: x\\r\\nConnection: close\\r\\n\\r\\n").await.unwrap();
    let mut buf = Vec::new();
    READ
    assert!(String::from_utf8_lossy(&buf).starts_with("HTTP/1.1 404"));
}
'''

# (plant name, base: "stub" or "impl", edits)
PLANTS = [
    ("a1-5xx-via-app", "stub", [append(G2, '''
#[sqlx::test(migrations = "./migrations")]
async fn get_failure_is_500(pool: SqlitePool) {
    let (s, _) = call(app(AppState { pool }), Request::get("/notes/1").body(Body::empty()).unwrap()).await;
    assert_eq!(s, StatusCode::INTERNAL_SERVER_ERROR);
}
''')]),
    ("a2-listener-timeout", "stub", [append(G2, LISTENER.replace(
        "READ", "tokio::time::timeout(std::time::Duration::from_secs(5), s.read_to_end(&mut buf)).await.unwrap().unwrap();"))]),
    ("a2-listener-no-timeout", "stub", [append(G2, LISTENER.replace("READ", "s.read_to_end(&mut buf).await.unwrap();"))]),
    ("a3-fake-repo", "stub", [append(G1, '''
struct Fake;
impl NoteRepo for Fake {
    fn get(&self, id: i64) -> Option<Note> {
        Some(Note { id, title: "hi".into() })
    }
}

#[sqlx::test(migrations = "./migrations")]
async fn repo_returns_the_note(_pool: SqlitePool) {
    assert_eq!(Fake.get(7).map(|n| n.title), Some("hi".to_string()));
}
''')]),
    ("a3b-extractor-rejection", "stub", [append(G2, '''
#[sqlx::test(migrations = "./migrations")]
async fn malformed_json_is_400(pool: SqlitePool) {
    let (s, _) = call(router(AppState { pool }), post_json("not json")).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
}
''')]),
    ("s2-query-macro", "impl", [replace("src/lib.rs",
        '''    sqlx::query_as::<_, Note>("SELECT id, title FROM notes WHERE id = ?")
        .bind(id)
        .fetch_optional(pool)''',
        '''    sqlx::query_as!(Note, "SELECT id, title FROM notes WHERE id = ?", id)
        .fetch_optional(pool)''')]),
    ("s4a-dup-migration-version", "stub", [
        write("migrations/0002_tags.sql", "CREATE TABLE tags (name TEXT);\n"),
        write("migrations/0002_flags.sql", "CREATE TABLE flags (name TEXT);\n")]),
    ("s5-file-db-in-checkout", "stub", [append(G1, '''
#[tokio::test]
async fn creates_in_a_file_db() {
    let pool = SqlitePool::connect("sqlite://notes.db?mode=rwc").await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    assert_eq!(create_note(&pool, "hi").await.unwrap().title, "hi");
}
''')]),
    ("t2-like-case", "stub", [replace(G3, 'assert_eq!(title_matches(&pool, "alpha").await, 1);',
                                       'assert_eq!(title_matches(&pool, "alpha").await, 0);')]),
    ("t2-affinity", "stub", [replace(G3, 'assert_eq!(stored_type(&pool, "12").await, "integer");',
                                      'assert_eq!(stored_type(&pool, "12").await, "text");')]),
    ("t2-division", "stub", [replace(G3, 'assert_eq!(int_ratio(&pool, -7, 2).await, -3);',
                                      'assert_eq!(int_ratio(&pool, -7, 2).await, -4);')]),
    ("t2-dates-as-text", "stub", [replace(G3, 'assert!(!text_before(&pool, "2026-1-5", "2026-01-10").await);',
                                           'assert!(text_before(&pool, "2026-1-5", "2026-01-10").await);')]),
    ("t2-rowid-reuse", "stub", [replace(G3, 'assert_eq!(create_note(&pool, "c").await.unwrap().id, b.id);',
                                         'assert_eq!(create_note(&pool, "c").await.unwrap().id, b.id + 1);')]),
    ("t2-order-unsorted", "stub", [replace(G3, '''    let mut got = list_titles(&pool).await;
    got.sort();
    assert_eq!(got, ["alpha", "mid", "zeta"]);''',
                                            '''    assert_eq!(list_titles(&pool).await, ["zeta", "alpha", "mid"]);''')]),
]


def git(cwd, *a):
    return subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True, text=True).stdout


def main():
    # Build every patch first; replace the plants directory only if all apply.
    built = {}
    for name, base, edits in PLANTS:
        with tempfile.TemporaryDirectory() as d:
            w = os.path.join(d, "c")
            shutil.copytree(CRATE, w)
            if base == "impl":
                shutil.copy(IMPL, os.path.join(w, "src", "lib.rs"))
            git(w, "init", "-q")
            git(w, "add", "-A")
            git(w, "-c", "user.name=x", "-c", "user.email=x@x", "-c", "commit.gpgsign=false", "commit", "-qm", "base")
            for e in edits:
                p = os.path.join(w, e[1])
                if e[0] == "append":
                    with open(p, "a") as fh:
                        fh.write(e[2])
                elif e[0] == "write":
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    with open(p, "w") as fh:
                        fh.write(e[2])
                else:
                    s = open(p).read()
                    if s.count(e[2]) != 1:
                        sys.exit(f"{name}: anchor not found once in {e[1]}")
                    open(p, "w").write(s.replace(e[2], e[3]))
            git(w, "add", "-A")
            built[f"{name}.{base}.patch"] = git(w, "diff", "--cached")
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".patch"):
            os.remove(os.path.join(OUT, f))
    for f, patch in built.items():
        with open(os.path.join(OUT, f), "w") as fh:
            fh.write(patch)
        print(f, len(patch.splitlines()))


main()
