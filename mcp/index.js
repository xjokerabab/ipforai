#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { EnvHttpProxyAgent, fetch } from "undici";
import { z } from "zod";

const API_BASE = process.env.IPFORAI_API || "https://ipforai.cc";
const V4_BASE = process.env.IPFORAI_V4_PROBE || "https://v4-probe.ipforai.cc";
const TIMEOUT_MS = 10000;
const VERSION = "0.2.0";

// Node's fetch ignores HTTPS_PROXY / HTTP_PROXY. Users who route AI traffic
// through a proxy would otherwise see their direct exit instead of the real one.
const dispatcher = new EnvHttpProxyAgent();

async function getJson(url) {
  const res = await fetch(url, {
    dispatcher,
    signal: AbortSignal.timeout(TIMEOUT_MS),
    headers: { "User-Agent": `ipforai-mcp/${VERSION}` },
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

async function profile(ip) {
  const body = await getJson(`${API_BASE}/json?ip=${encodeURIComponent(ip)}`);
  return { slot: body.ipv4 || body.ipv6, disclaimer: body.disclaimer };
}

// Same exit detection as the ipforai CLI: v4-probe has only an A record, so even
// behind a proxy it reveals the IPv4 exit; the main host reveals IPv6 when present.
async function detectExits() {
  const [v4, main] = await Promise.allSettled([
    getJson(`${V4_BASE}/api/ip-profile/echo`),
    getJson(`${API_BASE}/api/ip-profile/echo`),
  ]);
  let ipv4 = v4.status === "fulfilled" ? v4.value.ip : null;
  let ipv6 = null;
  if (main.status === "fulfilled") {
    if (main.value.addressFamily === "ipv6") ipv6 = main.value.ip;
    else if (!ipv4) ipv4 = main.value.ip;
  }
  return { ipv4, ipv6 };
}

function summarizeWeather(statusData, reachData) {
  const services = {};
  const statusMap = statusData?.services || {};
  const reachMap = reachData?.services || {};
  const ids = [...new Set([...Object.keys(statusMap), ...Object.keys(reachMap)])];

  for (const id of ids) {
    const st = statusMap[id];
    const rc = reachMap[id];
    const regions = {};
    if (rc?.regions) {
      for (const [code, cell] of Object.entries(rc.regions)) {
        regions[code] = cell.latencyMs ? `${cell.status} (${cell.latencyMs}ms)` : cell.status;
      }
    }
    services[id] = {
      officialStatus: st?.indicator ?? "unknown",
      description: st?.description ?? null,
      syncedAt: st?.syncedAt ?? null,
      pageUrl: st?.pageUrl ?? null,
      regionalApiReachability: regions,
    };
  }
  return {
    regions: reachData?.regions || [],
    services,
    url: `${API_BASE}/weather`,
  };
}

function result(data) {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function failure(message) {
  return { content: [{ type: "text", text: message }], isError: true };
}

const server = new McpServer({ name: "ipforai", version: VERSION });

server.registerTool(
  "check_my_ip",
  {
    title: "Check my exit IP for AI services",
    description:
      "Detect this machine's public IPv4/IPv6 exit (honoring HTTPS_PROXY) and return its network " +
      "profile from ipforai.cc: location, ASN, network/access/routing type, proxy and risk signals, " +
      "environment score, and availability for ChatGPT, Claude, Gemini, Grok and other AI services. " +
      "Describes the network only, not account status.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  async () => {
    try {
      const exits = await detectExits();
      if (!exits.ipv4 && !exits.ipv6) return failure("Could not detect a public exit IP from ipforai.cc.");
      const [p4, p6] = await Promise.all([
        exits.ipv4 ? profile(exits.ipv4) : null,
        exits.ipv6 ? profile(exits.ipv6) : null,
      ]);
      return result({
        ipv4: p4?.slot ?? null,
        ipv6: p6?.slot ?? null,
        disclaimer: (p4 || p6).disclaimer,
      });
    } catch (err) {
      return failure(`ipforai.cc lookup failed: ${err.message}`);
    }
  },
);

server.registerTool(
  "lookup_ip",
  {
    title: "Look up an IP for AI services",
    description:
      "Return the ipforai.cc network profile of a given IPv4 or IPv6 address: location, ASN, " +
      "network/access/routing type, proxy and risk signals, environment score, and availability " +
      "for ChatGPT, Claude, Gemini, Grok and other AI services. Profile lookup only, no live connectivity test.",
    inputSchema: { ip: z.string().describe("IPv4 or IPv6 address, e.g. 8.8.8.8") },
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  async ({ ip }) => {
    try {
      const { slot, disclaimer } = await profile(ip.trim());
      return result({ ...slot, disclaimer });
    } catch (err) {
      return failure(`ipforai.cc lookup failed: ${err.message}`);
    }
  },
);

server.registerTool(
  "check_ai_weather",
  {
    title: "Check AI official status and regional API reachability",
    description:
      "Check live official service status (Claude, ChatGPT, Gemini, Grok) and 7-region direct API " +
      "reachability (JP, US, SG, GB, HK, TW, CN) from ipforai.cc to tell whether an outage is on the AI provider side.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  async () => {
    try {
      const [statusRes, reachRes] = await Promise.allSettled([
        getJson(`${API_BASE}/api/service-status`),
        getJson(`${API_BASE}/api/region-reachability`),
      ]);
      const statusData = statusRes.status === "fulfilled" ? statusRes.value : null;
      const reachData = reachRes.status === "fulfilled" ? reachRes.value : null;
      if (!statusData && !reachData) return failure("Could not fetch AI weather data from ipforai.cc.");
      return result(summarizeWeather(statusData, reachData));
    } catch (err) {
      return failure(`ipforai.cc weather lookup failed: ${err.message}`);
    }
  },
);

server.registerTool(
  "lookup_asn",
  {
    title: "Look up an ASN or hosting/ISP operator",
    description:
      "Search the global ASN database on ipforai.cc (120k+ ASNs with PeeringDB metadata) by ASN number " +
      "(e.g. AS2497, 25820) or operator name (e.g. Vultr, DMIT, IIJ) to distinguish datacenter/VPS from residential ISP.",
    inputSchema: { query: z.string().describe("ASN number or operator keyword, e.g. AS2497 or Vultr") },
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  async ({ query }) => {
    try {
      const q = query.trim();
      if (!q) return failure("Please provide an ASN number or operator name.");
      const data = await getJson(`${API_BASE}/api/asn?q=${encodeURIComponent(q)}`);
      return result({
        query: data.query,
        totalIndexed: data.totalIndexed,
        results: data.results,
        url: `${API_BASE}/datacenters?q=${encodeURIComponent(q)}`,
      });
    } catch (err) {
      return failure(`ipforai.cc ASN lookup failed: ${err.message}`);
    }
  },
);

await server.connect(new StdioServerTransport());
