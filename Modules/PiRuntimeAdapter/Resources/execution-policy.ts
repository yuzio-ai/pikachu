import {
    createBashToolDefinition,
    createEditToolDefinition,
    createWriteToolDefinition,
    type ExtensionAPI,
    type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import type { TSchema } from "typebox";

export default function executionPolicy(pi: ExtensionAPI) {
    const mode = process.env.PIKACHU_EXECUTION_MODE;
    if (mode !== "interactive" && mode !== "plan") throw new Error("Invalid Pikachu execution mode");
    const tools = ["read", "grep", "find", "ls"];

    function requireApproval<T extends TSchema, Details, State>(
        tool: ToolDefinition<T, Details, State>,
        title: string,
    ) {
        const name = `pikachu_${tool.name}`;
        tools.push(name);
        pi.registerTool({
            ...tool,
            name,
            async execute(id, params, signal, onUpdate, ctx) {
                const message = `工作目录：${JSON.stringify(ctx.cwd)}\n\n${JSON.stringify(params, null, 2)}`;
                const approved = !signal?.aborted && ctx.hasUI &&
                    await ctx.ui.confirm(title, message, { timeout: 120_000, signal });
                if (!approved || signal?.aborted) throw new Error("用户未批准此操作。");
                return tool.execute(id, params, signal, onUpdate, ctx);
            },
        });
    }

    if (mode === "interactive") {
        requireApproval(createBashToolDefinition(process.cwd()), "允许运行命令？");
        requireApproval(createEditToolDefinition(process.cwd()), "允许编辑文件？");
        requireApproval(createWriteToolDefinition(process.cwd()), "允许写入文件？");
    }
    pi.on("session_start", () => { pi.setActiveTools(tools); });
    pi.on("before_agent_start", () => {
        pi.setActiveTools(tools);
        if (mode === "plan") {
            return { message: {
                customType: "pikachu-plan",
                content: "当前为计划模式。按需读取和搜索，给出可实施的计划。文件修改和命令执行留到执行阶段。",
                display: false,
            } };
        }
    });
    pi.registerCommand("pikachu-verify-policy", {
        description: "Verify the current Pikachu tool policy",
        async handler(nonce, ctx) {
            const active = [...pi.getActiveTools()].sort();
            const expected = [...tools].sort();
            if (JSON.stringify(active) === JSON.stringify(expected)) {
                ctx.ui.setStatus("pikachu-policy", `${mode}:${nonce}`);
            }
        },
    });
}
