// End-to-end check of MacBeeb's debug adapter over TCP, as VS Code talks
// to it: node test/smoke.js PORT PROGRAM.bin SOURCE.s LINE, or with a
// BeebAsm source as PROGRAM (it's assembled and run).
const net = require("net");

const [port, program, source, line] = process.argv.slice(2);
const socket = net.connect({ host: "127.0.0.1", port: Number(port) });
let buffer = Buffer.alloc(0);
let seq = 1;
const waiting = [];
const events = [];

function send(command, args = {}) {
  const body = JSON.stringify({ seq: seq++, type: "request", command, arguments: args });
  socket.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
  return new Promise((resolve) => waiting.push({ seq: seq - 1, resolve }));
}

function event(name, timeout = 15000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const check = () => {
      const index = events.findIndex((e) => e.event === name);
      if (index >= 0) return resolve(events.splice(index, 1)[0]);
      if (Date.now() - started > timeout) return reject(new Error(`no ${name} event`));
      setTimeout(check, 20);
    };
    check();
  });
}

socket.on("data", (data) => {
  buffer = Buffer.concat([buffer, data]);
  for (;;) {
    const end = buffer.indexOf("\r\n\r\n");
    if (end < 0) break;
    const length = Number(/Content-Length: (\d+)/i.exec(buffer.slice(0, end).toString())[1]);
    if (buffer.length < end + 4 + length) break;
    const message = JSON.parse(buffer.slice(end + 4, end + 4 + length).toString());
    buffer = buffer.slice(end + 4 + length);
    if (message.type === "response") {
      const index = waiting.findIndex((w) => w.seq === message.request_seq);
      if (index >= 0) waiting.splice(index, 1)[0].resolve(message);
    } else {
      events.push(message);
    }
  }
});

function check(condition, what) {
  if (!condition) {
    console.error(`FAIL: ${what}`);
    process.exit(1);
  }
  console.log(`ok: ${what}`);
}

(async () => {
  const init = await send("initialize", { adapterID: "macbeeb", linesStartAt1: true });
  check(init.success && init.body.supportsStepBack, "initialize");
  await event("initialized");
  const launch = await send("launch", program.endsWith(".asm") ? { source: program } : { program });
  check(launch.success, `launch ${launch.message || ""}`);
  const set = await send("setBreakpoints", { source: { path: source }, breakpoints: [{ line: Number(line) }] });
  check(set.body.breakpoints[0].verified, `breakpoint at line ${set.body.breakpoints[0].line}`);
  await send("configurationDone");
  const stopped = await event("stopped");
  check(stopped.body.reason === "breakpoint", "stopped at the breakpoint");
  const trace = await send("stackTrace", { threadId: 1 });
  check(trace.body.stackFrames[0].line === Number(line), `frame 0 is ${trace.body.stackFrames[0].name} at line ${trace.body.stackFrames[0].line}`);
  const vars = await send("variables", { variablesReference: 1 });
  console.log("   registers: " + vars.body.variables.map((v) => `${v.name}=${v.value}`).join(" "));
  await send("next", { threadId: 1 });
  check((await event("stopped")).body.reason === "step", "stepped");
  await send("disconnect");
  socket.end();
  process.exit(0);
})().catch((error) => {
  console.error(`FAIL: ${error.message}`);
  process.exit(1);
});
