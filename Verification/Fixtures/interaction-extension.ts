import { writeFileSync } from "node:fs";
import { join } from "node:path";

export default function (pi: any) {
  pi.registerCommand("interaction-dialogs", { description: "Four native dialog fixture; no inference", handler: async (_: any, ctx: any) => {
    const choice = await ctx.ui.select("交互选择", ["Alpha", "Beta"]);
    const confirmed = await ctx.ui.confirm("交互确认", "确认这次隔离验证？这不是工具执行审批。");
    const input = await ctx.ui.input("单行输入", "输入测试文本");
    const editor = await ctx.ui.editor("多行输入", "第一行\n第二行");
    writeFileSync(join(ctx.cwd, "dialog-result.json"), JSON.stringify({ choice, confirmed, input, editor }));
    ctx.ui.notify("四种交互完成", "info");
  }});
  pi.registerCommand("interaction-delay", { description: "Request after browsing away", handler: async (_: any, ctx: any) => {
    await new Promise(resolve => setTimeout(resolve, 1500));
    const value = await ctx.ui.input("后台会话请求", "请核对请求所属会话");
    writeFileSync(join(ctx.cwd, "delay-result.json"), JSON.stringify({ value: value ?? null }));
  }});
  pi.registerCommand("interaction-wait", { description: "Cancelable dialog", handler: async (_: any, ctx: any) => {
    const value = await ctx.ui.input("等待回复", "取消或停止");
    writeFileSync(join(ctx.cwd, "wait-result.json"), JSON.stringify({ value: value ?? null }));
  }});
  pi.registerCommand("interaction-expire", { description: "Expiring dialog", handler: async (_: any, ctx: any) => {
    const value = await ctx.ui.confirm("请求超时", "此请求自动过期", { timeout: 400 });
    writeFileSync(join(ctx.cwd, "expire-result.json"), JSON.stringify({ value }));
  }});
  pi.registerCommand("interaction-status", { description: "Nonmodal extension UI", handler: async (_: any, ctx: any) => {
    ctx.ui.setStatus("fixture", "扩展状态"); ctx.ui.setWidget("fixture", ["第一条扩展信息", "第二条扩展信息"]);
    ctx.ui.setTitle("Interaction Fixture"); ctx.ui.setEditorText("扩展建议草稿");
  }});
}
