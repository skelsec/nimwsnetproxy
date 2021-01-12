
import tables
import asyncdispatch, asynchttpserver, asyncnet 
import strutils

import struct/struct
import ws/ws
import winim/lean

proc error*(message: string, exception: ref Exception) =
    echo message
    echo exception.getStackTrace()

func toByteSeq*(str: string): seq[byte] {.inline.} =
  ## Converts a string to the corresponding byte sequence.
  @(str.toOpenArrayByte(0, str.high))

func toString*(bytes: openArray[byte]): string {.inline.} =
  ## Converts a byte sequence to the corresponding string.
  let length = bytes.len
  if length > 0:
    result = newString(length)
    copyMem(result.cstring, bytes[0].unsafeAddr, length)



func getSD*(token: string, data: string): string {.inline.} =
  ## generates an OK command
  return pack(">IH", len(token)+len(data)+6, 7) & token & data

func getOK*(token: string): string {.inline.} =
  ## generates an OK command
  return pack(">IH", len(token) + 6, 0) & token

func getCONT*(token: string): string {.inline.} =
  ## generates an OK command
  return pack(">IH", len(token) + 6, 4) & token

func getERR*(token: string, reason: string, extra: string): string {.inline.} =
  ## generates an OK command
  ## 
  var reason_d = pack(">I", len(reason)) & reason
  var extra_d = pack(">I", len(extra)) & extra
  var data = reason_d & extra_d
  return pack(">IH", len(token)+len(data)+6, 1) & token & data

proc handleClientIn(client: AsyncSocket, ws:WebSocket, token:string) {.async.} =
  echo "handleClientIn"
  while client.isClosed == false and ws.readyState == Open:
    try:
      var data = await client.recv(65536)
      if len(data) == 0:
        await ws.send(getOK(token), Opcode.Binary)
        break
      await ws.send(getSD(token, data), Opcode.Binary)
    except:
      await ws.send(getOK(token), Opcode.Binary)
      break
  
  echo "Client socket closing!"

var server = newAsyncHttpServer()

proc cb(req: Request) {.async.} =
  try:
    var dispatchTable = initTable[string, AsyncSocket]()
    if req.url.path == "/":
      var ws = await newWebSocket(req)
      #await ws.send("Welcome to simple echo server")
      echo "Client connected!"
      while ws.readyState == Open:
        var packet = await ws.receiveBinaryPacket()
        var x = toString(packet)
        var hdr = unpack(">IH16s", x)
        var cmdtype = hdr[1].getInt() #not sure??
        var token = hdr[2].getString()

        if cmdtype != 7:
          if dispatchTable.hasKey(token) == true:
            var socket = dispatchTable[token]
            if cmdtype == 0 or cmdtype == 1:
              socket.close()           
              dispatchTable.del(token)

          else:
            if cmdtype == 5:
              var com = unpack(">3sb", x[22 .. 26])
              var protocol = com[0].getString()
              var iptype = com[1].getChar()
              #if iptype == '\x04':
              var ip = intToStr(ord(x[26])) & "." & intToStr(ord(x[27])) & "." & intToStr(ord(x[28])) & "." & intToStr(ord(x[29]))
              var portdata = unpack(">H", x[30 .. 31])
              var port = portdata[0].getInt()
              var socket = newAsyncSocket(buffered = false)
              try:
                await socket.connect($ip, port.Port)
                echo("Connected!")
                asyncCheck handleClientIn(socket, ws, token)
                dispatchTable[token] = socket
                await ws.send(getCONT(token), Opcode.Binary)
              except:
                await ws.send(getERR(token, "Could not open socket", ""), Opcode.Binary)
              continue

        else:
          var payload = x[22 .. len(x)-1]
          if dispatchTable.hasKey(token) == true:
            if cmdtype == 7:
              try:
                await dispatchTable[token].send(payload)
              except:
                await ws.send(getERR(token, "remote socket broke", ""), Opcode.Binary)
                asyncCheck dispatchTable[token].send(payload)
                dispatchTable.del(token)
            else:
              echo "Unexpected data type! " & $cmdtype
          else:
            echo "Incoming data doesnt match any session! " & $cmdtype
        #await ws.send(x, Opcode.Binary)
    else:
      await req.respond(Http404, "Not found")
  except:
     echo "websocket client disconnected?"
     error("oops", getCurrentException())
     
proc NimMain() {.cdecl, importc.}

proc DllMain(hinstDLL: HINSTANCE, fdwReason: DWORD, lpvReserved: LPVOID) : BOOL {.stdcall, exportc, dynlib.} =
  NimMain()
  
  if fdwReason == DLL_PROCESS_ATTACH:
    waitFor server.serve(Port(8700), cb)

  return true