// Short-lived TURN credentials for direct book transfers (GH-60).
//
// The Cloudflare TURN key stays here, in the function's secrets; the app only
// ever gets credentials that expire. Deploy:
//
//   supabase secrets set CLOUDFLARE_TURN_KEY_ID=... CLOUDFLARE_TURN_API_TOKEN=...
//   supabase functions deploy turn-credentials
//
// Until both secrets are set it answers 503 and the app connects with STUN
// alone, falling back to Realtime when that is not enough.
//
// Nothing about the caller is kept or passed on: Cloudflare is not told who
// asked (no customIdentifier), and the function logs nothing about them.
import { createClient } from "jsr:@supabase/supabase-js@2";

// Long enough for any one transfer; the app asks again 5 minutes before.
const TTL_SECONDS = 60 * 60;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type IceServer = {
  urls: string | string[];
  username?: string;
  credential?: string;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const keyId = Deno.env.get("CLOUDFLARE_TURN_KEY_ID");
  const apiToken = Deno.env.get("CLOUDFLARE_TURN_API_TOKEN");
  if (!keyId || !apiToken) return json({ error: "not_configured" }, 503);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "unauthorized" }, 401);
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      global: { headers: { Authorization: authorization } },
      db: { schema: "cotime_book" },
    },
  );
  const { data: { user }, error: userError } = await supabase.auth.getUser();
  if (userError || !user) return json({ error: "unauthorized" }, 401);

  // Only someone in a room has a book to send or fetch. The row comes through
  // RLS, which shows a member their rows only while their membership is
  // active, so an anonymous account made just for credentials gets none.
  const { data: memberships, error: memberError } = await supabase
    .from("room_members")
    .select("room_id")
    .eq("user_id", user.id)
    .limit(1);
  if (memberError) return json({ error: "unavailable" }, 503);
  if (!memberships || memberships.length === 0) {
    return json({ error: "not_in_room" }, 403);
  }

  const response = await fetch(
    `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ ttl: TTL_SECONDS }),
    },
  );
  if (!response.ok) return json({ error: "turn_unavailable" }, 502);
  const { iceServers } = (await response.json()) as {
    iceServers?: IceServer[];
  };

  // The app gathers candidates before signalling (no trickle ICE), and an
  // alternate port 53 URL only makes that wait longer: browsers block it.
  const usable = (iceServers ?? [])
    .map((server) => ({
      ...server,
      urls: (Array.isArray(server.urls) ? server.urls : [server.urls]).filter(
        (url) => !/:53(\?|$)/.test(url),
      ),
    }))
    .filter((server) => server.urls.length > 0);

  return json({ iceServers: usable, ttl: TTL_SECONDS });
});
