export default function (pi: any) {
  pi.registerCommand("fixture-noop", { description: "No-model fixture", handler: async (_: any, ctx: any) => ctx.ui.notify("Fixture handled", "info") });
}
