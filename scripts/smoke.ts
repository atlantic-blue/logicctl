#!/usr/bin/env -S node --experimental-strip-types

import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { basename } from "node:path";
import { pathToFileURL } from "node:url";

/// Where a copy is allowed to sit. A project anywhere else is the work of a person.
const scratchRoot = "/tmp";

/// What Logic writes between the file of the project and the view the window shows.
const titleSeparator = ".logicx - ";

/// Where the signed binary sits when nothing names it.
const binaryByDefault = ".build/release/logicctl";

/// The windows Logic holds open while the reads answer.
///
/// A read walks to the project window, and the notes and the points of a region are in the Event
/// List of that region. Measured on this Mac on 2026-09-25: a read of a window that is not open
/// answers `element_not_found` and names the locator it looked for. So the refusal says this, and
/// an operator reads what to open rather than what failed.
export const windowsToOpen = "the Mixer open and the Event List of the region open";

/// What one command printed, on each channel, and the status it ended with.
///
/// The two channels are kept apart because a command that fails writes one line for a person on
/// the error channel and the envelope on the output channel. A reader of both at once finds no
/// envelope in the text and reports a tool that answered nothing.
export type CommandResult = {
  status: number;
  out: string;
  err: string;
};

export type Tools = {
  run: (command: string, args: readonly string[]) => CommandResult;
  resolve: (path: string) => string;
  print: (line: string) => void;
  refuse: (line: string) => void;
};

/// What the operator named on the make line.
export type Request = {
  binary: string;
  project: string;
  track: string;
  region: string;
};

/// The reads the run makes, in order. Each one leaves the project as it found it.
export function reads(request: Request): string[][] {
  return [
    ["status"],
    ["tracks", "list"],
    ["midi", "notes", "--track", request.track, "--region", request.region],
    ["automation", "list", "--track", request.track, "--region", request.region],
    ["plugins", "list", "--track", request.track],
  ];
}

/// The value given, or the default when nothing was given.
export function given(value: string | undefined, byDefault: string): string {
  return value === undefined || value.trim() === "" ? byDefault : value.trim();
}

/// The object an envelope carries, or nothing when the text is no envelope.
function envelopeOf(printed: string): Record<string, unknown> | null {
  let read: unknown;
  try {
    read = JSON.parse(printed.trim() === "" ? "null" : printed);
  } catch {
    return null;
  }
  if (typeof read !== "object" || read === null || Array.isArray(read)) {
    return null;
  }
  return read as Record<string, unknown>;
}

/// The code of the error an envelope carries, an empty string when it carries none, and nothing
/// when the text is no envelope at all.
export function errorOf(printed: string): string | null {
  const read = envelopeOf(printed);
  if (read === null || !("error" in read)) {
    return null;
  }
  const carried = read.error;
  if (carried === null) {
    return "";
  }
  if (typeof carried === "object") {
    const code: unknown = (carried as { code?: unknown }).code;
    if (typeof code === "string" && code !== "") {
      return code;
    }
  }
  return "an error it did not name";
}

/// The window an envelope names, or nothing when it names none.
export function windowOf(printed: string): string | null {
  const read = envelopeOf(printed);
  const data: unknown = read?.data;
  if (typeof data !== "object" || data === null) {
    return null;
  }
  const window: unknown = (data as { window?: unknown }).window;
  return typeof window === "string" ? window : null;
}

/// The reason to refuse the project named, or nothing when a read may go ahead.
///
/// Every link is resolved first, because `/tmp` on this Mac is a link to `/private/tmp`, and a
/// copy under the music folder can reach this run through a link as a path that looks like neither.
export function refusalForTheProject(project: string, tools: Tools): string | null {
  if (project.trim() === "") {
    return (
      "name the copy Logic has open, for example "
      + "make smoke PROJECT=/tmp/logicctl-fixtures/F-T13.logicx");
  }

  let sits = "";
  let root = "";
  try {
    sits = tools.resolve(project);
  } catch {
    return `${project} is not on this Mac, so it is not the copy Logic has open`;
  }
  try {
    root = tools.resolve(scratchRoot);
  } catch {
    return `${scratchRoot} is not on this Mac, and a smoke run reads a copy under it or nothing`;
  }

  if (sits !== root && !sits.startsWith(`${root}/`)) {
    return (
      `${project} sits at ${sits}, which is outside ${root}, so it is the work of a person. `
      + `A smoke run reads a copy under ${scratchRoot} and nothing else.`);
  }
  return null;
}

/// The reason to refuse what Logic has open, or nothing when it has the copy named.
///
/// No command that reads Logic answers the path of the open project, so the path comes from the
/// operator. This read is what stops a path that is right in form and wrong in fact: the title of
/// the project window carries the name of the project Logic actually holds.
export function refusalForTheWindow(project: string, printed: string): string | null {
  const named = basename(project).replace(/\.logicx$/, "");
  const window = windowOf(printed);
  if (window === null || window === "") {
    return `Logic shows no project window, so nothing says it has ${named} open`;
  }
  if (!window.startsWith(`${named}${titleSeparator}`)) {
    return `Logic shows ${window}, and the copy named is ${named}, so it has another project open`;
  }
  return null;
}

/// Runs every read against the Logic on this Mac and prints each envelope. Answers the exit code.
///
/// The count of reads is printed at the end, because the count is the evidence: a run that asked
/// nothing prints the same nothing as a run where every read answered.
export function smoke(request: Request, tools: Tools): number {
  const refusal = refusalForTheProject(request.project, tools);
  if (refusal !== null) {
    tools.refuse(refusal);
    return 1;
  }

  const asked = reads(request);
  if (asked.length === 0) {
    tools.refuse("there is no read to make, so this run proves nothing");
    return 1;
  }

  for (const [at, read] of asked.entries()) {
    const named = `logicctl ${read.join(" ")}`;
    const done = tools.run(request.binary, read);
    tools.print(named);
    tools.print(done.out.trim());
    if (done.err.trim() !== "") {
      tools.print(done.err.trim());
    }

    const error = errorOf(done.out);
    if (error === null) {
      tools.refuse(`${named} answered no envelope and it exited ${done.status}`);
      return 1;
    }
    if (error !== "") {
      tools.refuse(`${named} answered ${error}, and Logic needs ${windowsToOpen}`);
      return 1;
    }
    if (done.status !== 0) {
      tools.refuse(`${named} carried no error and it exited ${done.status}`);
      return 1;
    }

    if (at === 0) {
      const mistaken = refusalForTheWindow(request.project, done.out);
      if (mistaken !== null) {
        tools.refuse(mistaken);
        return 1;
      }
    }
  }

  tools.print(`reads: ${asked.length}`);
  return 0;
}

const shell: Tools = {
  run: (command, args) => {
    const done = spawnSync(command, [...args], { encoding: "utf8" });
    return {
      status: done.status ?? 1,
      out: done.stdout ?? "",
      err: done.stderr ?? "",
    };
  },
  resolve: (path) => realpathSync(path),
  print: (line) => process.stdout.write(`${line}\n`),
  refuse: (line) => process.stderr.write(`smoke: ${line}\n`),
};

const entry = process.argv[1];
if (entry !== undefined && import.meta.url === pathToFileURL(entry).href) {
  const request: Request = {
    binary: given(process.env.LOGICCTL_BINARY, binaryByDefault),
    project: given(process.env.PROJECT, ""),
    track: given(process.env.TRACK, "1"),
    region: given(process.env.REGION, "1"),
  };
  process.exit(smoke(request, shell));
}
