import * as fs from "fs";
import * as os from "os";
import * as path from "path";

import { Notice, Plugin, normalizePath } from "obsidian";

import {
  DEFAULT_SETTINGS,
  TranscribeerSettingTab,
  type TranscribeerSettings,
} from "./settings";

function readFileOptional(filePath: string): string | null {
  try {
    return fs.readFileSync(filePath, "utf-8").trim() || null;
  } catch {
    return null;
  }
}

/** Persistent data: tracks which sessions have already been imported. */
interface PluginData {
  settings: TranscribeerSettings;
  importedSessions: string[];
}

export default class TranscribeerPlugin extends Plugin {
  settings: TranscribeerSettings = DEFAULT_SETTINGS;
  private importedSessions: Set<string> = new Set();
  private watcher: fs.FSWatcher | null = null;
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;

  async onload(): Promise<void> {
    await this.loadSettings();
    this.addSettingTab(new TranscribeerSettingTab(this.app, this));

    this.addCommand({
      id: "import-all",
      name: "Import all new sessions",
      callback: () => this.importAllSessions(),
    });

    if (this.settings.enabled) {
      this.app.workspace.onLayoutReady(() => this.startWatcher());
    }
  }

  onunload(): void {
    this.stopWatcher();
  }

  // ── Settings persistence ───────────────────────────────────────────────────

  async loadSettings(): Promise<void> {
    const data: Partial<PluginData> = (await this.loadData()) ?? {};
    this.settings = { ...DEFAULT_SETTINGS, ...data.settings };
    this.importedSessions = new Set(data.importedSessions ?? []);
  }

  async saveSettings(): Promise<void> {
    const data: PluginData = {
      settings: this.settings,
      importedSessions: [...this.importedSessions],
    };
    await this.saveData(data);
  }

  // ── File watcher ───────────────────────────────────────────────────────────

  startWatcher(): void {
    this.stopWatcher();
    const dir = this.resolveSessionsDir();
    if (!fs.existsSync(dir)) {
      console.warn(`Transcribeer: sessions dir does not exist: ${dir}`);
      return;
    }

    this.watcher = fs.watch(dir, { recursive: true }, (_event, filename) => {
      if (!filename || !filename.endsWith("summary.md")) return;
      // Debounce: summary.md may be written incrementally
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      this.debounceTimer = setTimeout(() => this.importAllSessions(), 2000);
    });

    console.log(`Transcribeer: watching ${dir}`);
  }

  stopWatcher(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    if (this.watcher) {
      this.watcher.close();
      this.watcher = null;
      console.log("Transcribeer: watcher stopped");
    }
  }

  // ── Import logic ───────────────────────────────────────────────────────────

  async importAllSessions(): Promise<void> {
    const dir = this.resolveSessionsDir();
    if (!fs.existsSync(dir)) return;

    let imported = 0;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      if (this.importedSessions.has(entry.name)) continue;

      const summaryPath = path.join(dir, entry.name, "summary.md");
      if (!fs.existsSync(summaryPath)) continue;

      const ok = await this.importSession(dir, entry.name);
      if (ok) imported++;
    }

    if (imported > 0) {
      await this.saveSettings();
      new Notice(`Transcribeer: imported ${imported} session${imported > 1 ? "s" : ""}`);
    }
  }

  private async importSession(dir: string, sessionName: string): Promise<boolean> {
    const sessionDir = path.join(dir, sessionName);
    const summary = readFileOptional(path.join(sessionDir, "summary.md"));
    if (!summary) return false;

    const transcript = readFileOptional(path.join(sessionDir, "transcript.txt"));
    const content = this.buildNoteContent(sessionName, sessionDir, summary, transcript);

    const folder = normalizePath(this.settings.targetFolder);
    if (!this.app.vault.getAbstractFileByPath(folder)) {
      await this.app.vault.createFolder(folder);
    }

    const date = this.parseSessionDate(sessionName);
    const title = `Meeting ${date.toISOString().slice(0, 10)} ${date.toTimeString().slice(0, 5)}`;
    const notePath = normalizePath(`${folder}/${title}.md`);
    if (this.app.vault.getAbstractFileByPath(notePath)) {
      this.importedSessions.add(sessionName);
      return false;
    }

    await this.app.vault.create(notePath, content);
    this.importedSessions.add(sessionName);
    console.log(`Transcribeer: imported ${sessionName} → ${notePath}`);
    return true;
  }

  private buildNoteContent(
    sessionName: string,
    sessionDir: string,
    summary: string,
    transcript: string | null,
  ): string {
    const date = this.parseSessionDate(sessionName);
    const title = `Meeting ${date.toISOString().slice(0, 10)} ${date.toTimeString().slice(0, 5)}`;
    const tags = this.settings.tags
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);

    const lines: string[] = [
      "---",
      `date: ${date.toISOString().slice(0, 19)}`,
      `tags: [${tags.join(", ")}]`,
      `source: ${sessionDir}`,
      "---",
      "",
      `# ${title}`,
      "",
      summary,
    ];

    if (transcript) {
      const blockquoted = transcript
        .split("\n")
        .map((l) => `> ${l}`)
        .join("\n");
      lines.push("", "---", "", "> [!note]- Full Transcript", blockquoted);
    }

    return lines.join("\n") + "\n";
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  private resolveSessionsDir(): string {
    return this.settings.sessionsDir.replace(/^~/, os.homedir());
  }

  /**
   * Parse session folder name (YYYY-MM-DD-HHMM) into a Date.
   * Falls back to current time if parsing fails.
   */
  private parseSessionDate(name: string): Date {
    const match = name.match(/^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/);
    if (!match) return new Date();
    const [, year, month, day, hour, minute] = match;
    return new Date(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute));
  }
}
