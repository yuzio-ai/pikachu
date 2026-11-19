// Explicit verification-only extension. No automatic discovery, subagent or approval policy.
export default function (pi: any) {
  pi.registerCommand("fixture-handled", { description: "No-model handled prompt", handler: async (_: any, ctx: any) => {
    ctx.ui.notify("fixture handled", "info");
  }});
  pi.registerCommand("fixture-delay", { description: "Delayed command response", handler: async () => {
    await new Promise(resolve => setTimeout(resolve, 300));
  }});
  pi.registerCommand("fixture-dialogs", { description: "Dialog cancellation fixture", handler: async (_: any, ctx: any) => {
    const values = [
      await ctx.ui.select("Fixture select", ["A", "B"]),
      await ctx.ui.confirm("Fixture confirm", "Cancel fixture"),
      await ctx.ui.input("Fixture input", "fixture"),
      await ctx.ui.editor("Fixture editor", "fixture")
    ];
    ctx.ui.notify(JSON.stringify(values), "info");
  }});
  pi.registerCommand("fixture-timeout", { description: "Agent-side dialog timeout", handler: async (_: any, ctx: any) => {
    await ctx.ui.select("Fixture timeout", ["A"], { timeout: 100 });
    ctx.ui.notify("timeout completed", "info");
  }});
  pi.on("session_before_switch", async (_: any, ctx: any) => {
    if (!(await ctx.ui.confirm("Fixture switch", "Switch fixture"))) return { cancel: true };
  });
}
