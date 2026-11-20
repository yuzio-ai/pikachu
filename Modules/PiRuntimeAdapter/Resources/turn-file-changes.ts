import { execFile } from "node:child_process";
import { copyFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { promisify } from "node:util";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const exec = promisify(execFile);
const statusKey = "pikachu-turn-file-changes";

export default function turnFileChanges(pi: ExtensionAPI) {
    const scratchRoot = process.env.PIKACHU_TURN_CHANGES_DIRECTORY;
    if (!scratchRoot) return;

    const environment = { ...process.env };
    for (const key of Object.keys(environment)) {
        if (key.startsWith("GIT_")) delete environment[key];
    }
    environment.GIT_NO_LAZY_FETCH = "1";
    environment.GIT_TERMINAL_PROMPT = "0";

    function git(cwd: string, args: string[], env = environment) {
        return exec("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null", "-c", "core.splitIndex=false", "-C", cwd, ...args], {
            env, timeout: 4000, maxBuffer: 1024 * 1024,
        }).then(result => result.stdout);
    }

    async function openSnapshot(cwd: string) {
        const root = (await git(cwd, ["rev-parse", "--show-toplevel"])).replace(/\n$/, "");
        const [index, objects, format] = (await git(root, ["rev-parse", "--path-format=absolute",
            "--git-path", "index", "--git-path", "objects", "--show-object-format"]))
            .replace(/\n$/, "").split("\n");
        if (!index || !objects || (format !== "sha1" && format !== "sha256")) throw new Error("Invalid Git snapshot repository");
        const folder = await mkdtemp(join(scratchRoot!, "round-"));
        const objectDirectory = join(folder, "objects");
        try {
            await git(folder, ["init", "--bare", "--quiet", "--template=", "--object-format=" + format]);
            await writeFile(join(objectDirectory, "info", "alternates"), objects + "\n");
        } catch (error) {
            await rm(folder, { recursive: true, force: true }).catch(() => {});
            throw error;
        }
        return { root, index, folder, objectDirectory };
    }

    type Snapshot = Awaited<ReturnType<typeof openSnapshot>>;
    async function capture(snapshot: Snapshot) {
        const index = join(snapshot.folder, "index");
        await rm(index, { force: true });
        try {
            await copyFile(snapshot.index, index);
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        }
        const env = { ...environment, GIT_INDEX_FILE: index, GIT_OBJECT_DIRECTORY: snapshot.objectDirectory };
        // Snapshot the working files in a private index. Do not run repository filters or hooks.
        const filterKeys = await git(snapshot.root, ["config", "-z", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"])
            .catch(error => {
                if (error.code === 1) return "";
                throw error;
            });
        const filters = filterKeys.split("\0").filter(Boolean).flatMap(key => ["-c", key + (key.endsWith(".required") ? "=false" : "=")]);
        await git(snapshot.root, [...filters, "add", "--all", "--sparse", "--", "."], env);
        if (filters.length > 0) {
            // The copied index can reuse blobs produced by a now-disabled clean filter.
            // Rehash tracked files consistently so a timestamp-only change isn't an edit.
            await git(snapshot.root, [...filters, "add", "--renormalize", "--sparse", "--", "."], env);
        }
        return (await git(snapshot.root, [...filters, "write-tree"], env)).trim();
    }

    let snapshot: Snapshot | undefined;
    let started = false;
    let sawUser = false;

    // Hooks finish before Pi publishes the corresponding boundary or starts the next model call.
    pi.on("agent_start", async (_, ctx) => {
        if (started) return; // Pi can restart internally for retries and compaction.
        started = true;
        sawUser = false;
        try {
            snapshot = await openSnapshot(ctx.cwd);
            const tree = await capture(snapshot);
            ctx.ui.setStatus(statusKey, JSON.stringify({ phase: "start", folder: basename(snapshot.folder), tree }));
        } catch {
            if (snapshot) await rm(snapshot.folder, { recursive: true, force: true }).catch(() => {});
            snapshot = undefined;
        }
    });

    pi.on("message_start", async (event, ctx) => {
        if (event.message.role !== "user") return;
        if (sawUser && snapshot) {
            const tree = await capture(snapshot).catch(() => null);
            ctx.ui.setStatus(statusKey, JSON.stringify({ phase: "user", tree }));
        }
        sawUser = true;
    });

    pi.on("agent_settled", async (_, ctx) => {
        if (snapshot) {
            const tree = await capture(snapshot).catch(() => null);
            ctx.ui.setStatus(statusKey, JSON.stringify({ phase: "end", tree }));
        }
        snapshot = undefined;
        started = false;
        sawUser = false;
    });
}
