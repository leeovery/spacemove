import { closeMainWindow, PopToRootType, showHUD } from "@raycast/api";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const exec = promisify(execFile);
const HELPER = join(homedir(), ".local/bin/spacemove");

export type Space = {
  id: number;
  number?: number;
  name?: string;
  display: string;
  displayIndex: number;
  fullscreen: boolean;
  current: boolean;
  active: boolean;
};

type MoveResult = {
  ok: boolean;
  error?: string;
  method?: string;
  app?: string;
  to?: Space;
  followed?: boolean;
};

export function label(space: Space): string {
  return `${space.number}: ${space.name ?? `Desktop ${space.number}`}`;
}

function explain(error: unknown): string {
  const e = error as NodeJS.ErrnoException;
  if (e.code === "ENOENT") return `${HELPER} is missing: run make install in ~/Code/spacemove`;
  return e.message ?? String(error);
}

export async function listSpaces(): Promise<Space[]> {
  try {
    const { stdout } = await exec(HELPER, ["list", "--json"]);
    return JSON.parse(stdout);
  } catch (error) {
    throw new Error(explain(error));
  }
}

async function moveWindow(target: string, follow: boolean): Promise<MoveResult> {
  try {
    const { stdout } = await exec(HELPER, ["move", target, "--json", ...(follow ? ["--follow"] : [])]);
    return JSON.parse(stdout);
  } catch (error) {
    // The helper exits 1 with {"ok":false,"error":...} on stdout.
    const stdout = (error as { stdout?: string }).stdout;
    if (stdout) {
      try {
        return JSON.parse(stdout);
      } catch {
        // fall through
      }
    }
    return { ok: false, error: explain(error) };
  }
}

export async function moveAndReport(target: string, follow: boolean): Promise<void> {
  // Close first, so focus goes back to the window being moved. Pop to root as well: otherwise
  // Raycast keeps this list alive and reopens it with the old "Current" Space.
  const close = { clearRootSearch: true, popToRootType: PopToRootType.Immediate };
  await closeMainWindow(close);
  const result = await moveWindow(target, follow);
  if (!result.ok || !result.to) {
    await showHUD(`Couldn't move window: ${result.error ?? "unknown error"}`, close);
  } else if (result.method === "none") {
    await showHUD(`Already on ${label(result.to)}`, close);
  } else {
    await showHUD(`${result.app} → ${label(result.to)} (${result.method})`, close);
  }
}
