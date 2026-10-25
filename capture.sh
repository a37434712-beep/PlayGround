#!/usr/bin/env bash
# Capture desktop and mobile screenshots of the running preview.
# Exit 75 for temporary browser/navigation infrastructure failures, 1 for defects.
set -euo pipefail
cd "$(dirname "$0")"

: "${CAPTURE_URL:?Set CAPTURE_URL to the exact preview URL}"
: "${CAPTURE_DIR:?Set CAPTURE_DIR to the evidence directory}"
time_run() { /usr/bin/time -p "$@"; }

PLAYWRIGHT_ROOT="${PLAYWRIGHT_ROOT:-$HOME/.local/share/omgithub-playwright}"
export PLAYWRIGHT_ROOT CAPTURE_URL CAPTURE_DIR

time_run mkdir -p "$CAPTURE_DIR"
time_run rm -f "$CAPTURE_DIR/final-desktop.png" "$CAPTURE_DIR/final-mobile.png"

set +e
/usr/bin/time -p node <<'NODE'
const { existsSync, readFileSync } = require('node:fs')
const { join } = require('node:path')
const { createRequire } = require('node:module')

const root = process.env.PLAYWRIGHT_ROOT
const url = process.env.CAPTURE_URL
const outDir = process.env.CAPTURE_DIR
if (!root || !url || !outDir) {
  console.error('[defect] PLAYWRIGHT_ROOT, CAPTURE_URL and CAPTURE_DIR are required')
  process.exit(1)
}

if (process.platform === 'linux' && !process.env.DISPLAY) {
  const displayFile = join(root, 'display')
  if (existsSync(displayFile)) process.env.DISPLAY = ':' + readFileSync(displayFile, 'utf8').trim()
}

const configPath = join(root, process.platform === 'darwin' ? 'metal.json' : 'linux.json')
const config = JSON.parse(readFileSync(configPath, 'utf8'))
const requireFromRoot = createRequire(join(root, 'package.json'))
const { chromium } = requireFromRoot('playwright')

const transientPattern = /net::ERR_|ERR_(NAME_NOT_RESOLVED|CONNECTION|INTERNET|TUNNEL|EMPTY_RESPONSE|TIMED_OUT)|Timeout|timeout|Target (page|browser).*closed|browser has been closed|ECONNREFUSED|ECONNRESET|ENOTFOUND|EAI_AGAIN|socket hang up|Navigation failed because page crashed/i

const fail = (message, exitCode) => {
  throw Object.assign(new Error(message), { exitCode })
}
const transient = message => fail(`[transient] ${message}`, 75)
const defect = message => fail(`[defect] ${message}`, 1)

const readySelector = process.env.CAPTURE_READY_SELECTOR || '[data-app-ready="true"]'
const views = [['desktop', 1440, 900], ['mobile', 390, 844]]

async function main() {
let browser
try {
  const launchStart = Date.now()
  try {
    browser = await chromium.launch({ ...config.browser.launchOptions, timeout: 30000 })
  } catch (error) {
    transient(`browser launch failed: ${error.message}`)
  }
  console.log(`[capture] browser launched in ${Date.now() - launchStart} ms`)

  for (const [name, width, height] of views) {
    const viewStart = Date.now()
    const page = await browser.newPage({ viewport: { width, height } })
    page.setDefaultTimeout(30000)
    page.on('pageerror', error => console.error('[pageerror] ' + error.message))
    page.on('console', message => {
      if (message.type() === 'error') console.error('[console] ' + message.text())
    })

    let response
    try {
      response = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 })
    } catch (error) {
      if (transientPattern.test(error.message)) transient(`navigation failed for ${name}: ${error.message}`)
      defect(`navigation failed for ${name}: ${error.message}`)
    }
    if (!response) transient(`no response loading ${url} for ${name}`)
    if (!response.ok()) {
      const code = response.status()
      const message = `HTTP ${code} loading ${url} for ${name}`
      if ([408, 425, 429, 500, 502, 503, 504].includes(code)) transient(message)
      defect(message)
    }

    try {
      await page.waitForSelector(readySelector, { state: 'attached', timeout: 30000 })
    } catch (error) {
      defect(`rendered content never became ready (${readySelector}) for ${name}: ${error.message}`)
    }

    try {
      await page.evaluate(() => document.fonts.ready.then(() => true))
    } catch (error) {
      if (transientPattern.test(error.message)) transient(`font loading failed for ${name}: ${error.message}`)
    }

    const body = (await page.locator('body').innerText().catch(() => '')).trim()
    if (body.length < 10) defect(`page body is effectively empty for ${name}`)

    await page.waitForTimeout(900)
    try {
      await page.screenshot({ path: join(outDir, `final-${name}.png`), timeout: 30000 })
    } catch (error) {
      if (transientPattern.test(error.message)) transient(`screenshot failed for ${name}: ${error.message}`)
      defect(`screenshot failed for ${name}: ${error.message}`)
    }
    console.log(`[capture] ${name} ${width}x${height} captured in ${Date.now() - viewStart} ms`)
    await page.close().catch(() => {})
  }
} catch (error) {
  console.error(error.message)
  process.exitCode = error.exitCode || 1
} finally {
  await browser?.close().catch(error => {
    console.error(error.message)
    process.exitCode ||= 75
  })
}
}

main()
NODE
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

time_run test -s "$CAPTURE_DIR/final-desktop.png"
time_run test -s "$CAPTURE_DIR/final-mobile.png"
echo "Captured final-desktop.png and final-mobile.png in $CAPTURE_DIR"
