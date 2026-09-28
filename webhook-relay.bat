<# : FischHub webhook relay - keep this window open while farming so the webhook edits one message
@echo off
setlocal
title FischHub webhook relay
set "FH_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText($env:FH_SELF))"
echo.
pause
exit /b
#>
# ---------------------------------------------------------------- PowerShell part
# Discord only edits a webhook message with an HTTP PATCH, and the Matcha executor can only
# send GET and POST. FischHub posts the edit here instead; this relay sends it to Discord as
# the PATCH and hands Discord's answer back.
# - It listens on 127.0.0.1 only, so nothing outside this PC can reach it.
# - It forwards nothing but webhook message edits (/api/webhooks/<id>/<token>/messages/<id>),
#   and only to discord.com. GET /ping answers "fischhub-relay" so FischHub can find it.
# - Webhook URLs and tokens are never printed.

$ErrorActionPreference = 'Stop'
$Port = 47210
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Send-Response($stream, [int]$status, [string]$text) {
  $body = [Text.Encoding]::UTF8.GetBytes($text)
  $head = "HTTP/1.1 $status OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  $stream.Write($body, 0, $body.Length)
  $stream.Flush()
}

function Read-Exact($stream, [int]$count) {
  $buf = New-Object byte[] $count
  $got = 0
  while ($got -lt $count) {
    $n = $stream.Read($buf, $got, $count - $got)
    if ($n -le 0) { break }
    $got += $n
  }
  if ($got -lt $count) {
    $part = New-Object byte[] $got
    [Array]::Copy($buf, $part, $got)
    return ,$part
  }
  return ,$buf
}

function Read-Line($stream) {
  $sb = New-Object System.Text.StringBuilder
  while ($true) {
    $b = $stream.ReadByte()
    if ($b -lt 0) { return $null }
    if ($b -eq 10) { break }
    if ($b -ne 13) { [void]$sb.Append([char]$b) }
    if ($sb.Length -gt 16384) { return $null }
  }
  return $sb.ToString()
}

function Handle-Client($client) {
  $client.ReceiveTimeout = 5000
  $client.SendTimeout = 5000
  $stream = $client.GetStream()
  $requestLine = Read-Line $stream
  if (-not $requestLine) { return }
  $parts = $requestLine.Split(' ')
  $method = $parts[0]
  $path = if ($parts.Length -gt 1) { $parts[1] } else { '/' }
  $headers = @{}
  while ($true) {
    $line = Read-Line $stream
    if ($line -eq $null -or $line -eq '') { break }
    $i = $line.IndexOf(':')
    if ($i -gt 0) { $headers[$line.Substring(0, $i).Trim().ToLower()] = $line.Substring($i + 1).Trim() }
  }
  if ($headers['expect'] -eq '100-continue') {
    $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
    $stream.Write($cont, 0, $cont.Length)
  }
  $body = New-Object byte[] 0
  if ($headers['transfer-encoding'] -eq 'chunked') {
    $ms = New-Object System.IO.MemoryStream
    while ($true) {
      $sizeLine = Read-Line $stream
      if ($sizeLine -eq $null) { break }
      $size = [Convert]::ToInt32(($sizeLine.Split(';')[0]).Trim(), 16)
      if ($size -eq 0) { [void](Read-Line $stream); break }
      $chunk = Read-Exact $stream $size
      $ms.Write($chunk, 0, $chunk.Length)
      [void](Read-Line $stream)
    }
    $body = $ms.ToArray()
  } elseif ($headers['content-length']) {
    $len = [int]$headers['content-length']
    if ($len -gt 0 -and $len -le 1048576) { $body = Read-Exact $stream $len }
  }

  $plain = ($path -split '\?')[0]
  if ($plain -eq '/ping') {
    Send-Response $stream 200 '{"relay":"fischhub-relay"}'
    return
  }
  if ($method -ne 'POST' -or $plain -notmatch '^/api/webhooks/\d+/[A-Za-z0-9_\-]+/messages/\d+$') {
    Send-Response $stream 404 '{"message":"FischHub relay only forwards webhook message edits"}'
    return
  }

  $req = [System.Net.HttpWebRequest]::Create('https://discord.com' + $plain)
  $req.Method = 'PATCH'
  $req.ContentType = 'application/json'
  $req.UserAgent = 'FischHub-relay (https://github.com/j5cks/fischhub, 1)'
  $req.Timeout = 15000
  $req.ContentLength = $body.Length
  $rs = $req.GetRequestStream()
  $rs.Write($body, 0, $body.Length)
  $rs.Close()
  $resp = $null
  try {
    $resp = $req.GetResponse()
  } catch {
    $ex = $_.Exception
    while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
    if ($ex) { $resp = $ex.Response }
    if (-not $resp) {
      Send-Response $stream 502 ('{"message":"relay could not reach discord"}')
      Write-Host ("  " + (Get-Date -Format 'HH:mm:ss') + "  discord unreachable") -ForegroundColor Red
      return
    }
  }
  $status = [int]$resp.StatusCode
  $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
  $answer = $reader.ReadToEnd()
  $resp.Close()
  Send-Response $stream $status $answer
  $color = if ($status -lt 300) { 'Green' } else { 'Yellow' }
  Write-Host ("  " + (Get-Date -Format 'HH:mm:ss') + "  edited message -> discord $status") -ForegroundColor $color
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try {
  $listener.Start()
} catch {
  Write-Host ''
  Write-Host "  Port $Port is already in use - the relay is probably running in another window." -ForegroundColor Yellow
  exit 1
}
Write-Host ''
Write-Host '  FischHub webhook relay' -ForegroundColor Cyan
Write-Host "  listening on 127.0.0.1:$Port - keep this window open while farming, close it to stop."
Write-Host '  FischHub edits one Discord message while this runs, and posts new ones when it does not.'
Write-Host ''
while ($true) {
  $client = $listener.AcceptTcpClient()
  try {
    Handle-Client $client
  } catch {
    Write-Host ("  " + (Get-Date -Format 'HH:mm:ss') + "  request failed: " + $_.Exception.Message) -ForegroundColor Red
  } finally {
    $client.Close()
  }
}
