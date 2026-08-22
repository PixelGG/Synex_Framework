import { isIP } from "node:net";
import { DISCORD_LIMITS } from "./config.mjs";

const CONTROL_CHARACTERS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/gu;
const DIRECTIONAL_CONTROLS = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]/gu;

export function codePointLength(value) {
  return Array.from(String(value ?? "")).length;
}

export function truncate(value, maximum, suffix = "\u2026") {
  if (!Number.isInteger(maximum) || maximum < 0) {
    throw new TypeError("Truncation limit must be a non-negative integer.");
  }

  const characters = Array.from(String(value ?? ""));
  if (characters.length <= maximum) return characters.join("");
  if (maximum === 0) return "";

  const suffixCharacters = Array.from(suffix);
  if (suffixCharacters.length >= maximum) {
    return suffixCharacters.slice(0, maximum).join("");
  }

  return characters
    .slice(0, maximum - suffixCharacters.length)
    .concat(suffixCharacters)
    .join("");
}

export function normalizeText(value, { maxLines = 24 } = {}) {
  const normalized = String(value ?? "")
    .normalize("NFC")
    .replace(/\r\n?/gu, "\n")
    .replace(CONTROL_CHARACTERS, "")
    .replace(DIRECTIONAL_CONTROLS, "")
    .replace(/\t/gu, "  ")
    .split("\n")
    .slice(0, maxLines)
    .map((line) => line.replace(/[ \t]+$/gu, ""))
    .join("\n")
    .replace(/\n{3,}/gu, "\n\n")
    .trim();

  return normalized;
}

export function sanitizeUntrusted(value, { limit = 1024, maxLines = 12 } = {}) {
  const safe = normalizeText(value, { maxLines })
    .split("\n")
    .map((line) => line.replace(/^\s*#{1,6}\s+/u, ""))
    .join("\n")
    .replace(/`+/gu, "\u02cb")
    .replace(/\]\s*\(/gu, "] (")
    .replace(/@(everyone|here)\b/giu, "\uff20$1")
    .replace(/<(@[!&]?|#)(\d+)>/gu, (_, prefix, identifier) => `\u2039${prefix.replace("@", "\uff20")}${identifier}\u203a`)
    .replace(/</gu, "\u2039")
    .replace(/>/gu, "\u203a")
    .replace(/([\\*_~|\[\]])/gu, "\\$1");

  return truncate(safe, limit);
}

export function safeHttpsUrl(value) {
  if (typeof value !== "string" || value.trim() === "") return null;

  try {
    const url = new URL(value.trim());
    if (url.protocol !== "https:" || url.username || url.password || url.port || url.hash) {
      return null;
    }

    return url.toString();
  } catch {
    return null;
  }
}

export function safePublicHttpsUrl(value) {
  const safe = safeHttpsUrl(value);
  if (!safe) return null;

  const hostname = new URL(safe).hostname.replace(/^\[|\]$/gu, "").replace(/\.+$/u, "").toLowerCase();
  if (
    isIP(hostname) !== 0 ||
    hostname === "localhost" ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local") ||
    hostname.endsWith(".internal") ||
    !hostname.includes(".")
  ) {
    return null;
  }

  return safe;
}

export function safeMarkdownLink(label, value) {
  const url = safeHttpsUrl(value);
  if (!url) return null;

  const safeLabel = sanitizeUntrusted(label, { limit: 80, maxLines: 1 })
    .replace(/[\[\]]/gu, "")
    .trim();
  if (!safeLabel) return null;
  return `[${safeLabel}](${url.replace(/\)/gu, "%29")})`;
}

export function parseMultilineList(value, { maxItems = 6, itemLimit = 180 } = {}) {
  const lines = normalizeText(value, { maxLines: Math.max(maxItems * 4, 24) })
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !/^```/u.test(line))
    .map((line) => line.replace(/^(?:[-*+\u2022]\s+|\d+[.)]\s+)/u, ""))
    .map((line) => sanitizeUntrusted(line, { limit: itemLimit, maxLines: 1 }))
    .filter(Boolean);

  return lines.slice(0, maxItems);
}

export function bulletList(items, { additional = 0 } = {}) {
  const rendered = items.filter(Boolean).map((item) => `\u2022 ${item}`);
  if (additional > 0) rendered.push(`+ ${additional} additional`);
  return rendered.join("\n");
}

export function parseProgress(value) {
  const progress = Number(value);
  if (!Number.isInteger(progress) || progress < 0 || progress > 100) {
    throw new Error("Progress must be a whole number from 0 to 100.");
  }
  return progress;
}

export function progressBar(value, segments = 20) {
  const progress = parseProgress(value);
  if (!Number.isInteger(segments) || segments < 1 || segments > 40) {
    throw new Error("Progress bar segments must be an integer from 1 to 40.");
  }

  const filled = Math.round((progress / 100) * segments);
  return `${"\u25b0".repeat(filled)}${"\u25b1".repeat(segments - filled)}  **${progress}%**`;
}

export function formatDuration(startedAt, completedAt) {
  const started = Date.parse(startedAt);
  const completed = Date.parse(completedAt);
  if (!Number.isFinite(started) || !Number.isFinite(completed) || completed < started) {
    return "Not available";
  }

  const totalSeconds = Math.max(0, Math.round((completed - started) / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

function prepareEmbedText(value, maximum, maxLines = 32) {
  return truncate(normalizeText(value, { maxLines }), maximum);
}

function normalizeTimestamp(value) {
  if (!value) return undefined;
  const timestamp = new Date(value);
  if (Number.isNaN(timestamp.getTime())) return undefined;
  return timestamp.toISOString();
}

function fitEmbedTotal(embed) {
  const targets = [];

  if (embed.description) {
    targets.push({
      get: () => embed.description,
      set: (value) => {
        if (value) embed.description = value;
        else delete embed.description;
      },
      minimum: 0,
    });
  }

  for (let index = embed.fields.length - 1; index >= 0; index -= 1) {
    targets.push({
      get: () => embed.fields[index].value,
      set: (value) => {
        embed.fields[index].value = value;
      },
      minimum: 1,
    });
  }

  for (let index = embed.fields.length - 1; index >= 0; index -= 1) {
    targets.push({
      get: () => embed.fields[index].name,
      set: (value) => {
        embed.fields[index].name = value;
      },
      minimum: 1,
    });
  }

  if (embed.footer?.text) {
    targets.push({
      get: () => embed.footer.text,
      set: (value) => {
        embed.footer.text = value;
      },
      minimum: 1,
    });
  }

  if (embed.author?.name) {
    targets.push({
      get: () => embed.author.name,
      set: (value) => {
        embed.author.name = value;
      },
      minimum: 1,
    });
  }

  if (embed.title) {
    targets.push({
      get: () => embed.title,
      set: (value) => {
        embed.title = value;
      },
      minimum: 1,
    });
  }

  for (const target of targets) {
    const overflow = embedTextLength(embed) - DISCORD_LIMITS.embedTotal;
    if (overflow <= 0) break;

    const current = target.get();
    const currentLength = codePointLength(current);
    const nextLength = Math.max(target.minimum, currentLength - overflow);
    target.set(truncate(current, nextLength));
  }

  if (embedTextLength(embed) > DISCORD_LIMITS.embedTotal) {
    throw new Error("Embed text cannot be reduced to Discord's total character limit.");
  }
}

export function embedTextLength(embed) {
  let total = codePointLength(embed.title) + codePointLength(embed.description);
  total += codePointLength(embed.author?.name) + codePointLength(embed.footer?.text);

  for (const field of embed.fields ?? []) {
    total += codePointLength(field.name) + codePointLength(field.value);
  }

  return total;
}

export function finalizeEmbed(input) {
  const embed = {
    title: prepareEmbedText(input.title, DISCORD_LIMITS.title, 4),
    color: Number.isInteger(input.color) ? input.color : undefined,
    fields: (input.fields ?? [])
      .slice(0, DISCORD_LIMITS.fields)
      .map((field) => ({
        name: prepareEmbedText(field.name, DISCORD_LIMITS.fieldName, 4),
        value: prepareEmbedText(field.value, DISCORD_LIMITS.fieldValue, 20),
        inline: Boolean(field.inline),
      }))
      .filter((field) => field.name && field.value),
  };

  const description = prepareEmbedText(input.description, DISCORD_LIMITS.description, 32);
  if (description) embed.description = description;

  const url = safeHttpsUrl(input.url);
  if (url) embed.url = url;

  const authorName = prepareEmbedText(input.author?.name, DISCORD_LIMITS.author, 2);
  if (authorName) {
    embed.author = { name: authorName };
    const authorIcon = safeHttpsUrl(input.author?.icon_url);
    if (authorIcon) embed.author.icon_url = authorIcon;
    const authorUrl = safeHttpsUrl(input.author?.url);
    if (authorUrl) embed.author.url = authorUrl;
  }

  const footerText = prepareEmbedText(input.footer?.text, DISCORD_LIMITS.footer, 2);
  if (footerText) {
    embed.footer = { text: footerText };
    const footerIcon = safeHttpsUrl(input.footer?.icon_url);
    if (footerIcon) embed.footer.icon_url = footerIcon;
  }

  const timestamp = normalizeTimestamp(input.timestamp);
  if (timestamp) embed.timestamp = timestamp;

  fitEmbedTotal(embed);
  return embed;
}

export function validatePayload(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("Discord payload must be an object.");
  }

  if (!Array.isArray(payload.embeds) || payload.embeds.length < 1 || payload.embeds.length > DISCORD_LIMITS.embeds) {
    throw new Error("Discord payload must contain between one and ten embeds.");
  }

  if (
    !payload.allowed_mentions ||
    !Array.isArray(payload.allowed_mentions.parse) ||
    payload.allowed_mentions.parse.length !== 0 ||
    Object.keys(payload.allowed_mentions).some((key) => key !== "parse")
  ) {
    throw new Error("Discord payload must suppress all automatic mentions.");
  }

  if (payload.username && codePointLength(payload.username) > DISCORD_LIMITS.username) {
    throw new Error("Discord webhook username exceeds its character limit.");
  }

  let combinedEmbedLength = 0;
  for (const embed of payload.embeds) {
    if (codePointLength(embed.title) > DISCORD_LIMITS.title) throw new Error("Embed title exceeds its limit.");
    if (codePointLength(embed.description) > DISCORD_LIMITS.description) throw new Error("Embed description exceeds its limit.");
    if ((embed.fields?.length ?? 0) > DISCORD_LIMITS.fields) throw new Error("Embed contains too many fields.");
    if (codePointLength(embed.author?.name) > DISCORD_LIMITS.author) throw new Error("Embed author exceeds its limit.");
    if (codePointLength(embed.footer?.text) > DISCORD_LIMITS.footer) throw new Error("Embed footer exceeds its limit.");
    combinedEmbedLength += embedTextLength(embed);

    for (const field of embed.fields ?? []) {
      if (codePointLength(field.name) > DISCORD_LIMITS.fieldName) throw new Error("Embed field name exceeds its limit.");
      if (codePointLength(field.value) > DISCORD_LIMITS.fieldValue) throw new Error("Embed field value exceeds its limit.");
    }
  }

  if (combinedEmbedLength > DISCORD_LIMITS.embedTotal) {
    throw new Error("Embeds exceed Discord's combined text limit.");
  }

  return true;
}
