// Explicit M0-only extension. No automatic discovery, subagent or approval policy.
export default function (pi: any) {
  pi.registerCommand("m0-handled", { description: "No-model handled prompt", handler: async (_: any, ctx: any) => {
    ctx.ui.notify("m0 handled", "info");
  }});
  pi.registerCommand("m0-delay", { description: "Delayed command response", handler: async () => {
    await new Promise(resolve => setTimeout(resolve, 300));
  }});
  pi.registerCommand("m0-dialogs", { description: "Dialog cancellation fixture", handler: async (_: any, ctx: any) => {
    const values = [
      await ctx.ui.select("M0 select", ["A", "B"]),
      await ctx.ui.confirm("M0 confirm", "Cancel fixture"),
      await ctx.ui.input("M0 input", "fixture"),
      await ctx.ui.editor("M0 editor", "fixture")
    ];
    ctx.ui.notify(JSON.stringify(values), "info");
  }});
  pi.registerCommand("m0-timeout", { description: "Agent-side dialog timeout", handler: async (_: any, ctx: any) => {
    await ctx.ui.select("M0 timeout", ["A"], { timeout: 100 });
    ctx.ui.notify("timeout completed", "info");
  }});
  pi.on("session_before_switch", async (_: any, ctx: any) => {
    if (!(await ctx.ui.confirm("M0 switch", "Switch fixture"))) return { cancel: true };
  });
}
