# /md2email — Render a Markdown file as PDF and email it

Converts a Markdown file to a PDF (via Playwright Chromium) and sends it to a
recipient using AWS SES. Useful for sending documentation, reports, or audit
outputs without leaving the terminal.

## Usage

```
/md2email <path-to-markdown-file> <recipient-email>
```

Example:
```
/md2email docs/e2e_fork_tests.md johan@bluenine.se
```

## Steps

### 1. Ensure dependencies are installed

```bash
pip3 install markdown boto3 2>/dev/null | tail -1
```

Playwright Chromium is expected at `e2e/node_modules/playwright-core` (already
installed as part of the e2e suite). If missing:
```bash
cd e2e && npm install && npx playwright install chromium
```

### 2. Convert Markdown → HTML → PDF

```bash
MDFILE="<absolute path to the .md file>"
PDFFILE="/tmp/$(basename "$MDFILE" .md).pdf"
HTMLFILE="/tmp/$(basename "$MDFILE" .md).html"

python3 - <<'PYEOF'
import sys, pathlib, markdown

md_path = "$MDFILE"
html_path = "$HTMLFILE"
content = pathlib.Path(md_path).read_text()
body = markdown.markdown(content, extensions=['tables', 'fenced_code'])
html = f"""<!DOCTYPE html><html><head>
<meta charset="utf-8">
<style>
  body {{ font-family: -apple-system, sans-serif; max-width: 900px;
         margin: 40px auto; padding: 0 20px; line-height: 1.6; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1em 0; }}
  th, td {{ border: 1px solid #ddd; padding: 8px 12px; text-align: left; }}
  th {{ background: #f5f5f5; font-weight: 600; }}
  code {{ background: #f0f0f0; padding: 2px 5px; border-radius: 3px; font-size: 0.9em; }}
  pre {{ background: #f0f0f0; padding: 16px; border-radius: 6px; overflow-x: auto; }}
  pre code {{ background: none; padding: 0; }}
  h1, h2, h3 {{ border-bottom: 1px solid #eee; padding-bottom: 8px; }}
</style>
</head><body>{body}</body></html>"""
pathlib.Path(html_path).write_text(html)
print(f"HTML written: {html_path}")
PYEOF

node - <<'JSEOF'
const { chromium } = require('./e2e/node_modules/playwright-core');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('file://$HTMLFILE', { waitUntil: 'networkidle' });
  await page.pdf({ path: '$PDFFILE', format: 'A4', margin: { top: '20mm', bottom: '20mm', left: '15mm', right: '15mm' }, printBackground: true });
  await browser.close();
  console.log('PDF written: $PDFFILE');
})();
JSEOF
```

### 3. Send via AWS SES

SES is configured in `us-west-2` under the `121-api` AWS profile. Export the
profile before invoking the Python below:

```bash
export AWS_PROFILE=121-api

python3 - <<'PYEOF'
import boto3, base64, pathlib

pdf_path = "$PDFFILE"
recipient = "<recipient-email>"
subject = "$(basename "$MDFILE" .md)"
sender = "noreply@yakyak.ai"   # must be SES-verified

pdf_bytes = pathlib.Path(pdf_path).read_bytes()

# Build a raw MIME message with PDF attachment
import email.mime.multipart, email.mime.text, email.mime.base, email.encoders
msg = email.mime.multipart.MIMEMultipart()
msg['Subject'] = subject
msg['From'] = sender
msg['To'] = recipient
msg.attach(email.mime.text.MIMEText(f"Please find the document attached: {subject}", 'plain'))
part = email.mime.base.MIMEBase('application', 'pdf')
part.set_payload(pdf_bytes)
email.encoders.encode_base64(part)
part.add_header('Content-Disposition', f'attachment; filename="{subject}.pdf"')
msg.attach(part)

ses = boto3.client('ses', region_name='us-west-2')
ses.send_raw_email(
    Source=sender,
    Destinations=[recipient],
    RawMessage={'Data': msg.as_string()},
)
print(f"Email sent to {recipient}")
PYEOF
```

## Notes

- AWS credentials must be configured (env vars or `~/.aws/credentials`). The
  IAM identity needs `ses:SendRawEmail` on the source address. Use
  `AWS_PROFILE=121-api`; the default profile fails with `InvalidClientTokenId`.
- SES lives in `us-west-2` for this account (same region as S3/ECR/EventBridge).
- `noreply@yakyak.ai` is the verified SES sender for this account.
- The Playwright step launches a headless Chromium; the `e2e/` working directory
  must be current when the `require` resolves (adjust path if calling from
  elsewhere).
- Tables and fenced code blocks are handled by the `tables` and `fenced_code`
  Python-Markdown extensions.
- The PDF is written to `/tmp/` and is not cleaned up automatically.
