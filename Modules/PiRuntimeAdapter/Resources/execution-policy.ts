import {
    createBashToolDefinition,
    createEditToolDefinition,
    createFindToolDefinition,
    createGrepToolDefinition,
    createLsToolDefinition,
    createReadToolDefinition,
    createWriteToolDefinition,
    type ExtensionAPI,
    type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import type { TSchema } from "typebox";

export default function executionPolicy(pi: ExtensionAPI) {
    const mode = process.env.PIKACHU_EXECUTION_MODE;
    const approval = process.env.PIKACHU_TOOL_APPROVAL;
    if (mode !== "interactive" && mode !== "plan" && mode !== "automatic") throw new Error("Invalid Pikachu execution mode");
    if (approval !== "never" && !(approval === "everyCall" && mode !== "automatic") &&
        !(approval === "mutations" && mode === "interactive")) throw new Error("Invalid Pikachu approval policy");
    const cwd = process.cwd();
    const tools: string[] = [];

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
                const details = { tool: tool.name, workingDirectory: ctx.cwd, parameters: params };
                const message = `pikachu.tool-approval.v1\n${JSON.stringify(details)}`;
                const approved = !signal?.aborted && ctx.hasUI &&
                    await ctx.ui.confirm(title, message, { timeout: 120_000, signal });
                if (!approved || signal?.aborted) throw new Error("用户未批准此操作。");
                return tool.execute(id, params, signal, onUpdate, ctx);
            },
        });
    }

    if (mode !== "automatic") {
        if (approval === "everyCall") {
            requireApproval(createReadToolDefinition(cwd), "允许读取文件？");
            requireApproval(createGrepToolDefinition(cwd), "允许搜索文件内容？");
            requireApproval(createFindToolDefinition(cwd), "允许查找文件？");
            requireApproval(createLsToolDefinition(cwd), "允许列出目录？");
        } else {
            tools.push("read", "grep", "find", "ls");
        }
        if (mode === "interactive") {
            if (approval === "never") {
                tools.push("bash", "edit", "write");
            } else {
                requireApproval(createBashToolDefinition(cwd), "允许运行命令？");
                requireApproval(createEditToolDefinition(cwd), "允许编辑文件？");
                requireApproval(createWriteToolDefinition(cwd), "允许写入文件？");
            }
        }
        pi.on("session_start", () => { pi.setActiveTools(tools); });
    } else {
        pi.on("session_start", (event) => {
            if (event.reason !== "resume") return;
            // Pi restores the historical tool names before this event. A plan or
            // approval-mode history may not have the native mutation tools active.
            const active = pi.getActiveTools();
            const registered = new Set(pi.getAllTools().map((tool) => tool.name));
            const missing = ["bash", "edit", "write"].filter((name) => registered.has(name) && !active.includes(name));
            if (missing.length > 0) pi.setActiveTools([...active, ...missing]);
        });
    }
    const instructions = {
        plan: "本轮制定计划。按需读取和搜索，给出可实施的计划。文件修改和命令执行留到执行阶段。",
        interactive: "本轮交互执行。直接回答问题，与用户讨论方案，并按用户明确的执行要求推进。",
        automatic: "本轮自主执行。根据用户目标自行拆解、执行和验证。能根据现有信息继续时直接推进，遇到必须由用户决定的阻塞时再询问。",
    };
    const fileReferenceInstruction =
        "在回复中提及或列出工作区文件（尤其是新建、修改或需要用户查看的文件）时，请使用 Markdown 链接引用其位置（如 `[文件名或相对路径](file:///绝对路径)`，需要定位行号时可用 `#L行号`），方便用户直接点击打开。";
    pi.on("before_agent_start", (event) => {
        if (mode !== "automatic") pi.setActiveTools(tools);
        return { systemPrompt: `${event.systemPrompt}\n\n${instructions[mode]}\n\n${fileReferenceInstruction}` };
    });
    if (mode === "automatic") return;
    pi.registerCommand("pikachu-verify-policy", {
        description: "Verify the current Pikachu tool policy",
        async handler(nonce, ctx) {
            const active = [...pi.getActiveTools()].sort();
            const expected = [...tools].sort();
            if (JSON.stringify(active) === JSON.stringify(expected)) {
                ctx.ui.setStatus("pikachu-policy", `${mode}:${approval}:${nonce}`);
            }
        },
    });
}
