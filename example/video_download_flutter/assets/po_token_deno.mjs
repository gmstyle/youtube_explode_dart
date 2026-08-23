// BotGuard PO Token generation for Deno (desktop/Linux/macOS/Windows).
// Same flow as assets/po_token.html + FreeTube's isolated Chromium session,
// but using Deno's native fetch instead of WebView fetch bridges.

const globalObj = globalThis;
globalObj.window = globalObj;
globalObj.self = globalObj;
globalObj.globalThis = globalObj;

// Minimal browser surface BotGuard expects in headless runtimes (Deno/Node).
globalObj.navigator = {
  userAgent:
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
  platform: 'Linux x86_64',
  language: 'en-US',
  languages: ['en-US', 'en'],
  webdriver: false,
};
globalObj.location = new URL('https://www.youtube.com/');
globalObj.document = {
  cookie: '',
  referrer: 'https://www.youtube.com/',
  createElement(tag) {
    return { tagName: tag.toUpperCase(), src: '', onload: null, onerror: null };
  },
  head: { appendChild(node) {} },
  body: { appendChild(node) {} },
};

function loadBotGuard(challengeData) {
  globalObj.vm = globalObj[challengeData.globalName];
  const program = challengeData.program;
  globalObj.vmFunctions = {};

  if (!globalObj.vm) throw new Error('[BotGuardClient]: VM not found in global object');
  if (!globalObj.vm.a) throw new Error('[BotGuardClient]: Could not load program');

  const vmFunctionsCallback = function (asyncSnapshotFn, shutdownFn, passEventFn, checkCameraFn) {
    globalObj.vmFunctions = {
      asyncSnapshotFunction: asyncSnapshotFn,
      shutdownFunction: shutdownFn,
      passEventFunction: passEventFn,
      checkCameraFunction: checkCameraFn,
    };
  };

  globalObj.vm.a(
    program,
    vmFunctionsCallback,
    true,
    globalObj.userInteractionElement,
    function () {},
    [[], []],
  );

  return new Promise(function (resolve, reject) {
    let i = 0;
    const id = setInterval(function () {
      if (globalObj.vmFunctions.asyncSnapshotFunction) {
        resolve(globalObj);
        clearInterval(id);
      } else if (i >= 10000) {
        reject(new Error('asyncSnapshotFunction not available after 10s'));
        clearInterval(id);
      }
      i++;
    }, 1);
  });
}

function snapshot(botguard, webPoSignalOutput) {
  return new Promise(function (resolve, reject) {
    if (!botguard.vmFunctions.asyncSnapshotFunction) {
      return reject(new Error('[BotGuardClient]: Async snapshot function not found'));
    }
    botguard.vmFunctions.asyncSnapshotFunction(
      function (response) {
        resolve(response);
      },
      [undefined, undefined, webPoSignalOutput, undefined],
    );
  });
}

function u8ToBase64(u8arr, urlSafe) {
  let bin = '';
  for (let i = 0; i < u8arr.byteLength; i++) bin += String.fromCharCode(u8arr[i]);
  let b64 = btoa(bin);
  return urlSafe ? b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '') : b64;
}

function base64ToU8(b64) {
  b64 = b64.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(b64);
  const u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return u8;
}

async function loadExternalScript(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to load script: ${url} (${res.status})`);
  const code = await res.text();
  // Run in global scope like a browser <script src> tag (FreeTube/Electron).
  (0, eval)(code);
}

async function httpFetch(url, options = {}) {
  const res = await fetch(url, options);
  const contentType = res.headers.get('content-type') ?? '';
  let body;
  if (contentType.includes('json') || contentType.includes('protobuf')) {
    try {
      body = await res.json();
    } catch {
      body = await res.text();
    }
  } else {
    body = await res.text();
  }
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} for ${url}: ${typeof body === 'string' ? body : JSON.stringify(body)}`);
  }
  return { status: res.status, body };
}

async function generatePoToken(videoId, context, initialAttestationDataSource, ytConfig) {
  const initialAttestationData = new Function(`return (${initialAttestationDataSource});`)();
  globalObj.yt = { config_: ytConfig };

  function pickChallengeCandidate(obj) {
    if (!obj) return null;
    if (obj.bgChallenge) return obj;
    if (obj.R && obj.R.bgChallenge) return obj.R;
    if (obj.challenge && obj.challenge.bgChallenge) return obj.challenge;
    if (obj.data && obj.data.bgChallenge) return obj.data;
    return null;
  }

  let challengeData = pickChallengeCandidate(initialAttestationData);

  let interpreterUrl =
    challengeData &&
    challengeData.bgChallenge &&
    challengeData.bgChallenge.interpreterUrl &&
    challengeData.bgChallenge.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue;

  if (!interpreterUrl) {
    const attResponse = await httpFetch(
      'https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false&alt=json',
      {
        method: 'POST',
        headers: {
          Accept: '*/*',
          'Content-Type': 'application/json',
          'X-Goog-Visitor-Id': context.client.visitorData,
          'X-Youtube-Client-Version': context.client.clientVersion,
          'X-Youtube-Client-Name': '1',
        },
        body: JSON.stringify({
          engagementType: 'ENGAGEMENT_TYPE_UNBOUND',
          eacrToken: initialAttestationData.T,
          context,
        }),
      },
    );
    challengeData = pickChallengeCandidate(attResponse.body);
    if (!challengeData || !challengeData.bgChallenge) {
      throw new Error('bgChallenge not found in att/get response');
    }
    interpreterUrl =
      challengeData.bgChallenge.interpreterUrl &&
      challengeData.bgChallenge.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue;
  }

  if (!interpreterUrl) throw new Error('interpreterUrl not found');
  if (interpreterUrl.startsWith('//')) interpreterUrl = `https:${interpreterUrl}`;

  await loadExternalScript(interpreterUrl);

  const webPoSignalOutput = [];
  const botguard = await loadBotGuard({
    globalName: challengeData.bgChallenge.globalName,
    program: challengeData.bgChallenge.program,
  });
  const botguardResponse = await snapshot(botguard, webPoSignalOutput);

  const requestKey = 'O43z0dpjhgX20SCx4KAo';
  const itResponse = await httpFetch(
    'https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT',
    {
      method: 'POST',
      headers: {
        'content-type': 'application/json+protobuf',
        'x-goog-api-key': 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw',
        'x-user-agent': 'grpc-web-javascript/0.1',
        'user-agent': globalObj.navigator.userAgent,
      },
      body: JSON.stringify([requestKey, botguardResponse]),
    },
  );

  const itData = itResponse.body;
  if (!Array.isArray(itData)) {
    throw new Error(`Could not parse integrity token response: ${JSON.stringify(itData)?.slice(0, 200)}`);
  }

  const integrityToken = typeof itData[0] === 'string' && itData[0].length > 0 ? itData[0] : null;
  const websafeFallbackToken =
    typeof itData[3] === 'string' && itData[3].length > 0 ? itData[3] : null;

  const getMinter = webPoSignalOutput[0];
  if (!getMinter) {
    if (websafeFallbackToken) {
      // Headless runtimes may not wire the minter callback; the fallback
      // token from GenerateIT still works for WEB player/GVS in practice.
      return websafeFallbackToken;
    }
    throw new Error('PMD:Undefined');
  }

  const tokenMaterial = integrityToken ?? websafeFallbackToken;
  if (!tokenMaterial) {
    throw new Error(`Could not get integrity token (response: ${JSON.stringify(itData)?.slice(0, 200)})`);
  }

  const mintCallback = await getMinter(base64ToU8(tokenMaterial));
  if (typeof mintCallback !== 'function') throw new Error('APF:Failed');
  const result = await mintCallback(new TextEncoder().encode(videoId));
  if (!result || !(result instanceof Uint8Array)) throw new Error('ODM:Invalid');

  return u8ToBase64(result, true);
}

// Read one JSON request from stdin, print one JSON response to stdout.
const inputText = await new Response(Deno.stdin.readable).text();
const input = JSON.parse(inputText.trim());

try {
  if (!input.initialAttestationDataSource) {
    throw new Error('initialAttestationDataSource missing from watch page');
  }
  const token = await generatePoToken(
    input.videoId,
    input.context,
    input.initialAttestationDataSource,
    input.ytConfig,
  );
  console.log(JSON.stringify({ success: true, token }));
} catch (e) {
  console.log(JSON.stringify({ success: false, error: e?.message ?? String(e) }));
  Deno.exit(1);
}
