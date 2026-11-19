export default function (pi: any) {
  pi.registerCommand("m2-noop", { description: "M2 no-model fixture", handler: async (_: any, ctx: any) => ctx.ui.notify("M2 handled", "info") });
}
