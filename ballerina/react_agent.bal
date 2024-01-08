import ballerina/log;
import ballerina/regex;
import ballerina/lang.value;

public isolated class ReActAgent {
    *BaseAgent;
    final string instructionPrompt;
    final ToolStore toolStore;
    final CompletionLlmModel|ChatLlmModel model;

    # Initialize an Agent.
    #
    # + model - LLM model instance
    # + tools - Tools to be used by the agent
    public isolated function init(CompletionLlmModel|ChatLlmModel model, (BaseToolKit|Tool)... tools) returns error? {
        self.toolStore = check new (...tools);
        self.model = model;
        self.instructionPrompt = constructReActPrompt(self.toolStore.extractToolInfo());
        log:printDebug("Instruction Prompt Generated Successfully", instructionPrompt = self.instructionPrompt);
    }

    isolated function decideNextTool(QueryProgress progress) returns ToolResponse|ChatResponse|LlmError {
        map<json>|string? context = progress.context;
        string contextPrompt = context is () ? "" : string `${"\n\n"}You can use these information if needed: ${context.toString()}$`;

        string reactPrompt = string `${self.instructionPrompt}${contextPrompt}
        
Question: ${progress.query}
${constructHistoryPrompt(progress.history)}
${THOUGHT_KEY}`;

        string llmResponse = check self.generate(reactPrompt);
        NextTool|ChatResponse|LlmInvalidGenerationError parsedResponse = parseLlmReponse(normalizeLlmResponse(llmResponse));
        if parsedResponse is ChatResponse {
            return parsedResponse;
        }
        return {
            tool: parsedResponse,
            generated: llmResponse
        };
    }

    # Generate ReAct response for the given prompt
    #
    # + prompt - ReAct prompt to decide the next tool
    # + return - ReAct response
    isolated function generate(string prompt) returns string|LlmConnectionError {
        string|error? llmResult = ();
        CompletionLlmModel|ChatLlmModel model = self.model;
        if model is CompletionLlmModel {
            llmResult = model.complete(prompt, stop = OBSERVATION_KEY);
        } else if model is ChatLlmModel { // TODO should be removed once the Ballerina issues is fixed
            llmResult = model.chatComplete([
                {
                    role: USER,
                    content: prompt
                }
            ], stop = OBSERVATION_KEY);
        }
        if llmResult is string {
            return llmResult;
        }
        return error LlmConnectionError("Geneartion Failed.", llmResult);
    }

}

isolated function constructReActPrompt(ToolInfo toolInfo) returns string {

    return string `System: Respond to the human as helpfully and accurately as possible. You have access to the following tools:

${toolInfo.toolIntro}

Use a json blob to specify a tool by providing an action key (tool name) and an action_input key (tool input).

Valid "action" values: "Final Answer" or ${toolInfo.toolList}

Provide only ONE action per $JSON_BLOB, as shown:

${BACKTICK}${BACKTICK}${BACKTICK}
{
  "action": $TOOL_NAME,
  "action_input": $INPUT_JSON
}
${BACKTICK}${BACKTICK}${BACKTICK}

Follow this format:

Question: input question to answer
Thought: consider previous and subsequent steps
Action:
${BACKTICK}${BACKTICK}${BACKTICK}
$JSON_BLOB
${BACKTICK}${BACKTICK}${BACKTICK}
Observation: action result
... (repeat Thought/Action/Observation N times)
Thought: I know what to respond
Action:
${BACKTICK}${BACKTICK}${BACKTICK}
{
  "action": "Final Answer",
  "action_input": "Final response to human"
}
${BACKTICK}${BACKTICK}${BACKTICK}

Begin! Reminder to ALWAYS respond with a valid json blob of a single action. Use tools if necessary. Respond directly if appropriate. Format is Action:${BACKTICK}${BACKTICK}${BACKTICK}$JSON_BLOB${BACKTICK}${BACKTICK}${BACKTICK}then Observation:.`;
}

isolated function normalizeLlmResponse(string llmResponse) returns string {
    string normalizedResponse = llmResponse.trim();
    if !normalizedResponse.includes("```") {
        if normalizedResponse.startsWith("{") && normalizedResponse.endsWith("}") {
            normalizedResponse = string `${"```"}${normalizedResponse}${"```"}`;
        } else {
            int? jsonStart = normalizedResponse.indexOf("{");
            int? jsonEnd = normalizedResponse.lastIndexOf("}");
            if jsonStart is int && jsonEnd is int {
                normalizedResponse = string `${"```"}${normalizedResponse.substring(jsonStart, jsonEnd + 1)}${"```"}`;
            }
        }
    }
    normalizedResponse = regex:replace(normalizedResponse, "```json", "```");
    normalizedResponse = regex:replaceAll(normalizedResponse, "\"\\{\\}\"", "{}");
    normalizedResponse = regex:replaceAll(normalizedResponse, "\\\\\"", "\"");
    return normalizedResponse;
}

isolated function parseLlmReponse(string llmResponse) returns NextTool|ChatResponse|LlmInvalidGenerationError {
    string[] content = regex:split(llmResponse + "<endtoken>", "```");
    if content.length() < 3 {
        log:printWarn("Unexpected LLM response is given", llmResponse = llmResponse);
        return error LlmInvalidGenerationError("Unable to extract the tool due to invalid generation", thought = llmResponse, instruction = "Tool execution failed due to invalid generation.");
    }

    map<json>|error jsonThought = content[1].fromJsonStringWithType();
    if jsonThought is error {
        log:printWarn("Invalid JSON is given as the action.", jsonThought);
        return error LlmInvalidGenerationError("Invalid JSON is given as the action.", jsonThought, thought = llmResponse, instruction = "Tool execution failed due to an invalid 'Action' JSON_BLOB.");
    }

    map<json> jsonAction = {};
    foreach [string, json] [key, value] in jsonThought.entries() {
        if key.toLowerAscii() == "action" {
            jsonAction["name"] = value;
        } else if key.toLowerAscii().matches(re `^action.?input`) {
            jsonAction["arguments"] = value;
        }
    }
    json input = jsonAction["arguments"];
    if jsonAction["name"].toString().toLowerAscii().matches(FINAL_ANSWER_REGEX) && input is string {
        return {
            content: input
        };
    }
    NextTool|error tool = jsonAction.fromJsonWithType();
    if tool is error {
        log:printError("Error while extracting action name and inputs from LLM response.", tool, llmResponse = llmResponse);
        return error LlmInvalidGenerationError("Generated 'Action' JSON_BLOB contains invalid action name or inputs.", tool, thought = llmResponse, instruction = "Tool execution failed due to an invalid schema for 'Action' JSON_BLOB.");
    }
    return {
        name: tool.name,
        arguments: tool.arguments
    };
}

isolated function constructHistoryPrompt(ExecutionStep[] history) returns string {
    string historyPrompt = "";
    foreach ExecutionStep step in history {
        string observationStr = getObservationString(step.observation);
        string thoughtStr = step.action.generated.toString();
        historyPrompt += string `${thoughtStr}${"\n"}Observation: ${observationStr}${"\n"}`;
    }
    return historyPrompt;
}

isolated function getErrorInfo(error 'e, string key) returns string? {
    map<value:Cloneable> detail = 'e.detail();
    if detail.hasKey(key) {
        value:Cloneable errorInfoValue = detail.get(key);
        if errorInfoValue is string {
            return errorInfoValue;
        }
    }
    return ();
}
