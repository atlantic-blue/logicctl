import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { countFromLog, prove, runIdsFrom } from "./prove.ts";
import type { CommandResult, Tools } from "./prove.ts";

const branch = "feat-one-scenario-runs-in-the-pipeline-on-request";
const head = "0baa37b0000000000000000000000000000000ab";
const scenario = "aScenarioRunsOnRequest";
const theRunThatWasAlreadyThere = 7;
const theRunTheDispatchMade = 9;

type Answer = {
  command: string;
  contains: string;
  result: CommandResult | (() => CommandResult);
};

type Recorder = {
  tools: Tools;
  asked: string[];
  printed: string[];
};

/// Answers the commands prove.ts runs, and records every one of them.
///
/// An answer matches on the command and on one word of its arguments, so a test names only the
/// answer it changes. A command the table does not answer fails the test, rather than reading
/// back as an empty string.
function recorder(answers: readonly Answer[]): Recorder {
  const asked: string[] = [];
  const printed: string[] = [];
  const run = (command: string, args: readonly string[]): CommandResult => {
    const whole = [command, ...args].join(" ");
    asked.push(whole);
    for (const answer of answers) {
      if (command === answer.command && whole.includes(answer.contains)) {
        return typeof answer.result === "function" ? answer.result() : answer.result;
      }
    }
    throw new Error(`the test answers no such command: ${whole}`);
  };
  const tools: Tools = {
    run,
    wait: async () => {},
    print: (line: string) => {
      printed.push(line);
    },
  };
  return { tools, asked, printed };
}

const ok = (output: string): CommandResult => ({ status: 0, output });

/// A clean tree, a pushed head, and a dispatch that makes one new run.
function happyAnswers(log: string, watchStatus: number): Answer[] {
  let listings = 0;
  return [
    { command: "git", contains: "--abbrev-ref", result: ok(`${branch}\n`) },
    { command: "git", contains: "status", result: ok("") },
    { command: "git", contains: "rev-parse HEAD", result: ok(`${head}\n`) },
    { command: "git", contains: "ls-remote", result: ok(`${head}\trefs/heads/${branch}\n`) },
    {
      command: "gh",
      contains: "run list",
      result: () => {
        listings = listings + 1;
        const ids =
          listings === 1
            ? [theRunThatWasAlreadyThere]
            : [theRunTheDispatchMade, theRunThatWasAlreadyThere];
        return ok(JSON.stringify(ids.map((databaseId) => ({ databaseId }))));
      },
    },
    { command: "gh", contains: "workflow run", result: ok("") },
    { command: "gh", contains: "run watch", result: { status: watchStatus, output: "" } },
    { command: "gh", contains: "run view", result: ok(log) },
  ];
}

function answersWith(log: string, watchStatus: number, change: Partial<Answer>): Answer[] {
  return happyAnswers(log, watchStatus).map((answer) =>
    answer.contains === change.contains ? { ...answer, ...change } : answer
  );
}

/// A person asks the pipeline for one scenario by name, and reads back a count they can trust.
describe("the proof route", () => {
  it("prints the count and succeeds when the scenario ran", async () => {
    const asked = recorder(happyAnswers("scenarios: 1\n", 0));
    const code = await prove(scenario, asked.tools);
    assert.equal(code, 0);
    assert.deepEqual(asked.printed, ["scenarios: 1"]);
  });

  it("asks for the scenario by name, on the branch it is standing on", async () => {
    const asked = recorder(happyAnswers("scenarios: 1\n", 0));
    await prove(scenario, asked.tools);
    const dispatch = asked.asked.find((line) => line.includes("workflow run"));
    assert.ok(dispatch !== undefined);
    assert.ok(dispatch.includes(`--ref ${branch}`), dispatch);
    assert.ok(dispatch.includes(`scenario=${scenario}`), dispatch);
  });

  it("waits for the run the dispatch made, not the one that was already there", async () => {
    const asked = recorder(happyAnswers("scenarios: 1\n", 0));
    await prove(scenario, asked.tools);
    assert.ok(
      asked.asked.some((line) => line.includes(`run watch ${theRunTheDispatchMade}`)),
      asked.asked.join("\n")
    );
  });

  it("prints the count and fails when no scenario ran, green run or not", async () => {
    const asked = recorder(happyAnswers("scenarios: 0\n", 0));
    const code = await prove(scenario, asked.tools);
    assert.notEqual(code, 0);
    assert.deepEqual(asked.printed, ["scenarios: 0"]);
  });

  it("reads a log with no count as zero, green run or not", async () => {
    const asked = recorder(happyAnswers("the job died before it counted anything\n", 0));
    const code = await prove(scenario, asked.tools);
    assert.notEqual(code, 0);
    assert.deepEqual(asked.printed, ["scenarios: 0"]);
  });

  it("fails when the scenario ran and failed", async () => {
    const asked = recorder(happyAnswers("scenarios: 1\n", 1));
    const code = await prove(scenario, asked.tools);
    assert.notEqual(code, 0);
    assert.deepEqual(asked.printed, ["scenarios: 1"]);
  });

  it("refuses a dirty working tree, and dispatches nothing", async () => {
    const asked = recorder(
      answersWith("scenarios: 1\n", 0, { contains: "status", result: ok(" M Package.swift\n") })
    );
    const code = await prove(scenario, asked.tools);
    assert.notEqual(code, 0);
    assert.deepEqual(asked.printed, []);
    assert.equal(
      asked.asked.find((line) => line.includes("workflow run")),
      undefined
    );
  });

  it("refuses a head the remote does not carry, and dispatches nothing", async () => {
    const somewhereElse = "1111111111111111111111111111111111111111";
    const asked = recorder(
      answersWith("scenarios: 1\n", 0, {
        contains: "ls-remote",
        result: ok(`${somewhereElse}\trefs/heads/${branch}\n`),
      })
    );
    const code = await prove(scenario, asked.tools);
    assert.notEqual(code, 0);
    assert.deepEqual(asked.printed, []);
    assert.equal(
      asked.asked.find((line) => line.includes("workflow run")),
      undefined
    );
  });

  it("refuses when the pipeline does not carry the route yet, and dispatches nothing", async () => {
    const asked = recorder(
      answersWith("scenarios: 1\n", 0, {
        contains: "run list",
        result: {
          status: 1,
          output:
            "HTTP 404: Not Found (https://api.github.com/repos/atlantic-blue/logicctl/actions/workflows/scenario.yml)\n",
        },
      })
    );
    const code = await prove(scenario, asked.tools);
    assert.notEqual(code, 0);
    assert.deepEqual(asked.printed, []);
    assert.equal(
      asked.asked.find((line) => line.includes("workflow run")),
      undefined
    );
  });

  it("refuses a branch the remote does not carry at all", async () => {
    const asked = recorder(
      answersWith("scenarios: 1\n", 0, { contains: "ls-remote", result: ok("") })
    );
    assert.notEqual(await prove(scenario, asked.tools), 0);
  });
});

describe("the listing of runs", () => {
  it("reads an answer that is not a listing as no runs", () => {
    assert.deepEqual(runIdsFrom("HTTP 404: Not Found"), []);
    assert.deepEqual(runIdsFrom(""), []);
  });

  it("reads the ids a listing carries", () => {
    assert.deepEqual(runIdsFrom('[{"databaseId":9},{"databaseId":7}]'), [9, 7]);
  });
});

describe("the count line", () => {
  it("reads the last count the log carries", () => {
    assert.equal(countFromLog("scenarios: 4\nscenarios: 2\n"), 2);
  });

  it("reads a log with no count line as nothing", () => {
    assert.equal(countFromLog("no count here\n"), null);
  });
});
