const std = @import("std");

pub const AdditionalProperties = union(enum) {
    any,
    null,
    allowed_types: []const std.meta.Tag(std.json.Value),
};

pub fn UnionParser(comptime T: type) type {
    return struct {
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!T {
            const json_value = try std.json.parseFromTokenSourceLeaky(std.json.Value, allocator, source, options);
            return try jsonParseFromValue(allocator, json_value, options);
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!T {
            inline for (std.meta.fields(T)) |field| {
                if (field.type == void) {
                    return @unionInit(T, field.name, {});
                } else if (std.json.parseFromValueLeaky(field.type, allocator, source, options)) |result| {
                    return @unionInit(T, field.name, result);
                } else |_| {}
            }
            return error.UnexpectedToken;
        }

        pub fn jsonStringify(self: T, stream: anytype) @TypeOf(stream.*).Error!void {
            switch (self) {
                inline else => |value| {
                    if (@TypeOf(value) != void) {
                        try stream.write(value);
                    }
                },
            }
        }
    };
}

pub fn EnumParser(comptime T: type) type {
    return struct {
        pub fn eql(a: T, b: T) bool {
            const tag_a = std.meta.activeTag(a);
            const tag_b = std.meta.activeTag(b);
            if (tag_a != tag_b) return false;

            return true;
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!T {
            const slice = try std.json.parseFromTokenSourceLeaky([]const u8, allocator, source, options);
            return try map_get(slice);
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!T {
            const slice = try std.json.parseFromValueLeaky([]const u8, allocator, source, options);
            return try map_get(slice);
        }

        pub fn jsonStringify(self: T, stream: anytype) @TypeOf(stream.*).Error!void {
            switch (self) {
                else => |val| try stream.write(@tagName(val)),
            }
        }

        fn map_get(slice: []const u8) !T {
            const fields = @typeInfo(T).@"enum".fields;
            inline for (fields) |field| {
                if (std.mem.eql(u8, slice, field.name)) {
                    return @field(T, field.name);
                }
            }

            return error.UnknownField;
        }
    };
}

pub const Object = std.json.ArrayHashMap(Value);
pub const Array = std.ArrayListUnmanaged(Value);

/// Represents any JSON value, potentially containing other JSON values.
/// A .float value may be an approximation of the original value.
/// Arbitrary precision numbers can be represented by .number_string values.
/// See also `std.json.ParseOptions.parse_numbers`.
pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    number_string: []const u8,
    string: []const u8,
    array: Array,
    object: Object,

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!Value {
        switch (source) {
            .null => return @unionInit(Value, "null", {}),
            .string => |string| return @unionInit(Value, "string", string),
            .integer => |integer| return @unionInit(Value, "integer", integer),
            .bool => |b| return @unionInit(Value, "bool", b),
            .float => |float| return @unionInit(Value, "float", float),
            .number_string => |number_string| return @unionInit(Value, "number_string", number_string),
            .object => {
                const result = try std.json.parseFromValueLeaky(Object, allocator, source, options);
                return @unionInit(Value, "object", result);
            },
            .array => {
                const result = try std.json.parseFromValueLeaky(Array, allocator, source, options);
                return @unionInit(Value, "array", result);
            },
        }

        return error.UnexpectedToken;
    }

    pub fn jsonStringify(value: @This(), jws: anytype) !void {
        switch (value) {
            .null => try jws.write(null),
            .bool => |inner| try jws.write(inner),
            .integer => |inner| try jws.write(inner),
            .float => |inner| try jws.write(inner),
            .number_string => |inner| try jws.print("{s}", .{inner}),
            .string => |inner| try jws.write(inner),
            .array => |inner| try jws.write(inner.items),
            .object => |inner| {
                try jws.beginObject();

                var it = inner.map.iterator();
                while (it.next()) |entry| {
                    try jws.objectField(entry.key_ptr.*);
                    try jws.write(entry.value_ptr.*);
                }

                try jws.endObject();
            },
        }
    }
};

/// Base class of requests, responses, and events.
pub const ProtocolMessage = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,

    /// Message type.
    type: union(enum) {
        pub usingnamespace UnionParser(@This());
        request,
        response,
        event,
        string: []const u8,
    },
};

pub const Request = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },

    /// The command to execute.
    command: []const u8,

    /// Object containing arguments for the command.
    arguments: ?Value = null,
};

pub const Event = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },

    /// Type of event.
    event: []const u8,

    /// Event-specific information.
    body: ?Value = null,
};

pub const Response = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const ErrorResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// A structured error message.
        @"error": ?Message = null,
    },
};

pub const CancelRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        cancel,
    },
    arguments: ?CancelArguments = null,
};

/// Arguments for `cancel` request.
pub const CancelArguments = struct {
    /// The ID (attribute `seq`) of the request to cancel. If missing no request is cancelled.
    /// Both a `requestId` and a `progressId` can be specified in one request.
    requestId: ?i32 = null,

    /// The ID (attribute `progressId`) of the progress to cancel. If missing no progress is cancelled.
    /// Both a `requestId` and a `progressId` can be specified in one request.
    progressId: ?[]const u8 = null,
};

pub const CancelResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const InitializedEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        initialized,
    },

    /// Event-specific information.
    body: ?Value = null,
};

pub const StoppedEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        stopped,
    },
    body: struct {
        /// The reason for the event.
        /// For backward compatibility this string is shown in the UI if the `description` attribute is missing (but it must not be translated).
        reason: union(enum) {
            pub usingnamespace UnionParser(@This());
            step,
            breakpoint,
            exception,
            pause,
            entry,
            goto,
            @"function breakpoint",
            @"data breakpoint",
            @"instruction breakpoint",
            string: []const u8,
        },

        /// The full reason for the event, e.g. 'Paused on exception'. This string is shown in the UI as is and can be translated.
        description: ?[]const u8 = null,

        /// The thread which was stopped.
        threadId: ?i32 = null,

        /// A value of true hints to the client that this event should not change the focus.
        preserveFocusHint: ?bool = null,

        /// Additional information. E.g. if reason is `exception`, text contains the exception name. This string is shown in the UI.
        text: ?[]const u8 = null,

        /// If `allThreadsStopped` is true, a debug adapter can announce that all threads have stopped.
        /// - The client should use this information to enable that all threads can be expanded to access their stacktraces.
        /// - If the attribute is missing or false, only the thread with the given `threadId` can be expanded.
        allThreadsStopped: ?bool = null,

        /// Ids of the breakpoints that triggered the event. In most cases there is only a single breakpoint but here are some examples for multiple breakpoints:
        /// - Different types of breakpoints map to the same location.
        /// - Multiple source breakpoints get collapsed to the same instruction by the compiler/runtime.
        /// - Multiple function breakpoints with different function names map to the same location.
        hitBreakpointIds: ?[]i32 = null,
    },
};

pub const ContinuedEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        continued,
    },
    body: struct {
        /// The thread which was continued.
        threadId: i32,

        /// If `allThreadsContinued` is true, a debug adapter can announce that all threads have continued.
        allThreadsContinued: ?bool = null,
    },
};

pub const ExitedEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        exited,
    },
    body: struct {
        /// The exit code returned from the debuggee.
        exitCode: i32,
    },
};

pub const TerminatedEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        terminated,
    },
    body: ?struct {
        /// A debug adapter may set `restart` to true (or to an arbitrary object) to request that the client restarts the session.
        /// The value is not interpreted by the client and passed unmodified as an attribute `__restart` to the `launch` and `attach` requests.
        restart: ?Value = null,
    } = null,
};

pub const ThreadEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        thread,
    },
    body: struct {
        /// The reason for the event.
        reason: union(enum) {
            pub usingnamespace UnionParser(@This());
            started,
            exited,
            string: []const u8,
        },

        /// The identifier of the thread.
        threadId: i32,
    },
};

pub const OutputEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        output,
    },
    body: struct {
        /// The output category. If not specified or if the category is not understood by the client, `console` is assumed.
        category: ?union(enum) {
            pub usingnamespace UnionParser(@This());
            /// Show the output in the client's default message UI, e.g. a 'debug console'. This category should only be used for informational output from the debugger (as opposed to the debuggee).
            console,
            /// A hint for the client to show the output in the client's UI for important and highly visible information, e.g. as a popup notification. This category should only be used for important messages from the debugger (as opposed to the debuggee). Since this category value is a hint, clients might ignore the hint and assume the `console` category.
            important,
            /// Show the output as normal program output from the debuggee.
            stdout,
            /// Show the output as error program output from the debuggee.
            stderr,
            /// Send the output to telemetry instead of showing it to the user.
            telemetry,
            string: []const u8,
        } = null,

        /// The output to report.
        /// ANSI escape sequences may be used to influence text color and styling if `supportsANSIStyling` is present in both the adapter's `Capabilities` and the client's `InitializeRequestArguments`. A client may strip any unrecognized ANSI sequences.
        /// If the `supportsANSIStyling` capabilities are not both true, then the client should display the output literally.
        output: []const u8,

        /// Support for keeping an output log organized by grouping related messages.
        group: ?enum {
            pub usingnamespace EnumParser(@This());
            /// Start a new group in expanded mode. Subsequent output events are members of the group and should be shown indented.
            /// The `output` attribute becomes the name of the group and is not indented.
            start,
            /// Start a new group in collapsed mode. Subsequent output events are members of the group and should be shown indented (as soon as the group is expanded).
            /// The `output` attribute becomes the name of the group and is not indented.
            startCollapsed,
            /// End the current group and decrease the indentation of subsequent output events.
            /// A non-empty `output` attribute is shown as the unindented end of the group.
            end,
        } = null,

        /// If an attribute `variablesReference` exists and its value is > 0, the output contains objects which can be retrieved by passing `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
        variablesReference: ?i32 = null,

        /// The source location where the output was produced.
        source: ?Source = null,

        /// The source location's line where the output was produced.
        line: ?i32 = null,

        /// The position in `line` where the output was produced. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
        column: ?i32 = null,

        /// Additional data to report. For the `telemetry` category the data is sent to telemetry, for the other categories the data is shown in JSON format.
        data: ?Value = null,

        /// A reference that allows the client to request the location where the new value is declared. For example, if the logged value is function pointer, the adapter may be able to look up the function's location. This should be present only if the adapter is likely to be able to resolve the location.
        /// This reference shares the same lifetime as the `variablesReference`. See 'Lifetime of Object References' in the Overview section for details.
        locationReference: ?i32 = null,
    },
};

pub const BreakpointEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        breakpoint,
    },
    body: struct {
        /// The reason for the event.
        reason: union(enum) {
            pub usingnamespace UnionParser(@This());
            changed,
            new,
            removed,
            string: []const u8,
        },

        /// The `id` attribute is used to find the target breakpoint, the other attributes are used as the new values.
        breakpoint: Breakpoint,
    },
};

pub const ModuleEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        module,
    },
    body: struct {
        /// The reason for the event.
        reason: enum {
            pub usingnamespace EnumParser(@This());
            new,
            changed,
            removed,
        },

        /// The new, changed, or removed module. In case of `removed` only the module id is used.
        module: Module,
    },
};

pub const LoadedSourceEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        loadedSource,
    },
    body: struct {
        /// The reason for the event.
        reason: enum {
            pub usingnamespace EnumParser(@This());
            new,
            changed,
            removed,
        },

        /// The new, changed, or removed source.
        source: Source,
    },
};

pub const ProcessEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        process,
    },
    body: struct {
        /// The logical name of the process. This is usually the full path to process's executable file. Example: /home/example/myproj/program.js.
        name: []const u8,

        /// The process ID of the debugged process, as assigned by the operating system. This property should be omitted for logical processes that do not map to operating system processes on the machine.
        systemProcessId: ?i32 = null,

        /// If true, the process is running on the same computer as the debug adapter.
        isLocalProcess: ?bool = null,

        /// Describes how the debug engine started debugging this process.
        startMethod: ?enum {
            pub usingnamespace EnumParser(@This());
            /// Process was launched under the debugger.
            launch,
            /// Debugger attached to an existing process.
            attach,
            /// A project launcher component has launched a new process in a suspended state and then asked the debugger to attach.
            attachForSuspendedLaunch,
        } = null,

        /// The size of a pointer or address for this process, in bits. This value may be used by clients when formatting addresses for display.
        pointerSize: ?i32 = null,
    },
};

pub const CapabilitiesEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        capabilities,
    },
    body: struct {
        /// The set of updated capabilities.
        capabilities: Capabilities,
    },
};

pub const ProgressStartEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        progressStart,
    },
    body: struct {
        /// An ID that can be used in subsequent `progressUpdate` and `progressEnd` events to make them refer to the same progress reporting.
        /// IDs must be unique within a debug session.
        progressId: []const u8,

        /// Short title of the progress reporting. Shown in the UI to describe the long running operation.
        title: []const u8,

        /// The request ID that this progress report is related to. If specified a debug adapter is expected to emit progress events for the long running request until the request has been either completed or cancelled.
        /// If the request ID is omitted, the progress report is assumed to be related to some general activity of the debug adapter.
        requestId: ?i32 = null,

        /// If true, the request that reports progress may be cancelled with a `cancel` request.
        /// So this property basically controls whether the client should use UX that supports cancellation.
        /// Clients that don't support cancellation are allowed to ignore the setting.
        cancellable: ?bool = null,

        /// More detailed progress message.
        message: ?[]const u8 = null,

        /// Progress percentage to display (value range: 0 to 100). If omitted no percentage is shown.
        percentage: ?f32 = null,
    },
};

pub const ProgressUpdateEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        progressUpdate,
    },
    body: struct {
        /// The ID that was introduced in the initial `progressStart` event.
        progressId: []const u8,

        /// More detailed progress message. If omitted, the previous message (if any) is used.
        message: ?[]const u8 = null,

        /// Progress percentage to display (value range: 0 to 100). If omitted no percentage is shown.
        percentage: ?f32 = null,
    },
};

pub const ProgressEndEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        progressEnd,
    },
    body: struct {
        /// The ID that was introduced in the initial `ProgressStartEvent`.
        progressId: []const u8,

        /// More detailed progress message. If omitted, the previous message (if any) is used.
        message: ?[]const u8 = null,
    },
};

pub const InvalidatedEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        invalidated,
    },
    body: struct {
        /// Set of logical areas that got invalidated. This property has a hint characteristic: a client can only be expected to make a 'best effort' in honoring the areas but there are no guarantees. If this property is missing, empty, or if values are not understood, the client should assume a single value `all`.
        areas: ?[]InvalidatedAreas = null,

        /// If specified, the client only needs to refetch data related to this thread.
        threadId: ?i32 = null,

        /// If specified, the client only needs to refetch data related to this stack frame (and the `threadId` is ignored).
        stackFrameId: ?i32 = null,
    },
};

pub const MemoryEvent = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        event,
    },
    event: enum {
        pub usingnamespace EnumParser(@This());
        memory,
    },
    body: struct {
        /// Memory reference of a memory range that has been updated.
        memoryReference: []const u8,

        /// Starting offset in bytes where memory has been updated. Can be negative.
        offset: i32,

        /// Number of bytes updated.
        count: i32,
    },
};

pub const RunInTerminalRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        runInTerminal,
    },
    arguments: RunInTerminalRequestArguments,
};

/// Arguments for `runInTerminal` request.
pub const RunInTerminalRequestArguments = struct {
    /// What kind of terminal to launch. Defaults to `integrated` if not specified.
    kind: ?enum {
        pub usingnamespace EnumParser(@This());
        integrated,
        external,
    } = null,

    /// Title of the terminal.
    title: ?[]const u8 = null,

    /// Working directory for the command. For non-empty, valid paths this typically results in execution of a change directory command.
    cwd: []const u8,

    /// List of arguments. The first argument is the command to run.
    args: [][]const u8,

    /// Environment key-value pairs that are added to or removed from the default environment.
    env: ?struct {
        pub const additional_properties: AdditionalProperties = &.{
            .string,
            .null,
        };
        map: Object,
    } = null,

    /// This property should only be set if the corresponding capability `supportsArgsCanBeInterpretedByShell` is true. If the client uses an intermediary shell to launch the application, then the client must not attempt to escape characters with special meanings for the shell. The user is fully responsible for escaping as needed and that arguments using special characters may not be portable across shells.
    argsCanBeInterpretedByShell: ?bool = null,
};

pub const RunInTerminalResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The process ID. The value should be less than or equal to 2147483647 (2^31-1).
        processId: ?i32 = null,

        /// The process ID of the terminal shell. The value should be less than or equal to 2147483647 (2^31-1).
        shellProcessId: ?i32 = null,
    },
};

pub const StartDebuggingRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        startDebugging,
    },
    arguments: StartDebuggingRequestArguments,
};

/// Arguments for `startDebugging` request.
pub const StartDebuggingRequestArguments = struct {
    /// Arguments passed to the new debug session. The arguments must only contain properties understood by the `launch` or `attach` requests of the debug adapter and they must not contain any client-specific properties (e.g. `type`) or client-specific features (e.g. substitutable 'variables').
    configuration: struct {
        pub const additional_properties: AdditionalProperties = .any;
        map: Object,
    },

    /// Indicates whether the new debug session should be started with a `launch` or `attach` request.
    request: enum {
        pub usingnamespace EnumParser(@This());
        launch,
        attach,
    },
};

pub const StartDebuggingResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const InitializeRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        initialize,
    },
    arguments: InitializeRequestArguments,
};

/// Arguments for `initialize` request.
pub const InitializeRequestArguments = struct {
    /// The ID of the client using this adapter.
    clientID: ?[]const u8 = null,

    /// The human-readable name of the client using this adapter.
    clientName: ?[]const u8 = null,

    /// The ID of the debug adapter.
    adapterID: []const u8,

    /// The ISO-639 locale of the client using this adapter, e.g. en-US or de-CH.
    locale: ?[]const u8 = null,

    /// If true all line numbers are 1-based (default).
    linesStartAt1: ?bool = null,

    /// If true all column numbers are 1-based (default).
    columnsStartAt1: ?bool = null,

    /// Determines in what format paths are specified. The default is `path`, which is the native format.
    pathFormat: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        path,
        uri,
        string: []const u8,
    } = null,

    /// Client supports the `type` attribute for variables.
    supportsVariableType: ?bool = null,

    /// Client supports the paging of variables.
    supportsVariablePaging: ?bool = null,

    /// Client supports the `runInTerminal` request.
    supportsRunInTerminalRequest: ?bool = null,

    /// Client supports memory references.
    supportsMemoryReferences: ?bool = null,

    /// Client supports progress reporting.
    supportsProgressReporting: ?bool = null,

    /// Client supports the `invalidated` event.
    supportsInvalidatedEvent: ?bool = null,

    /// Client supports the `memory` event.
    supportsMemoryEvent: ?bool = null,

    /// Client supports the `argsCanBeInterpretedByShell` attribute on the `runInTerminal` request.
    supportsArgsCanBeInterpretedByShell: ?bool = null,

    /// Client supports the `startDebugging` request.
    supportsStartDebuggingRequest: ?bool = null,

    /// The client will interpret ANSI escape sequences in the display of `OutputEvent.output` and `Variable.value` fields when `Capabilities.supportsANSIStyling` is also enabled.
    supportsANSIStyling: ?bool = null,
};

pub const InitializeResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// The capabilities of this debug adapter.
    body: ?Capabilities = null,
};

pub const ConfigurationDoneRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        configurationDone,
    },
    arguments: ?ConfigurationDoneArguments = null,
};

/// Arguments for `configurationDone` request.
pub const ConfigurationDoneArguments = struct { map: Object };

pub const ConfigurationDoneResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const LaunchRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        launch,
    },
    arguments: LaunchRequestArguments,
};

/// Arguments for `launch` request. Additional attributes are implementation specific.
pub const LaunchRequestArguments = struct {
    /// If true, the launch request should launch the program without enabling debugging.
    noDebug: ?bool = null,

    /// Arbitrary data from the previous, restarted session.
    /// The data is sent as the `restart` attribute of the `terminated` event.
    /// The client should leave the data intact.
    __restart: ?Value = null,
};

pub const LaunchResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const AttachRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        attach,
    },
    arguments: AttachRequestArguments,
};

/// Arguments for `attach` request. Additional attributes are implementation specific.
pub const AttachRequestArguments = struct {
    /// Arbitrary data from the previous, restarted session.
    /// The data is sent as the `restart` attribute of the `terminated` event.
    /// The client should leave the data intact.
    __restart: ?Value = null,
};

pub const AttachResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const RestartRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        restart,
    },
    arguments: ?RestartArguments = null,
};

/// Arguments for `restart` request.
pub const RestartArguments = struct {
    /// The latest version of the `launch` or `attach` configuration.
    arguments: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        LaunchRequestArguments: LaunchRequestArguments,
        AttachRequestArguments: AttachRequestArguments,
    } = null,
};

pub const RestartResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const DisconnectRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        disconnect,
    },
    arguments: ?DisconnectArguments = null,
};

/// Arguments for `disconnect` request.
pub const DisconnectArguments = struct {
    /// A value of true indicates that this `disconnect` request is part of a restart sequence.
    restart: ?bool = null,

    /// Indicates whether the debuggee should be terminated when the debugger is disconnected.
    /// If unspecified, the debug adapter is free to do whatever it thinks is best.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportTerminateDebuggee` is true.
    terminateDebuggee: ?bool = null,

    /// Indicates whether the debuggee should stay suspended when the debugger is disconnected.
    /// If unspecified, the debuggee should resume execution.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportSuspendDebuggee` is true.
    suspendDebuggee: ?bool = null,
};

pub const DisconnectResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const TerminateRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        terminate,
    },
    arguments: ?TerminateArguments = null,
};

/// Arguments for `terminate` request.
pub const TerminateArguments = struct {
    /// A value of true indicates that this `terminate` request is part of a restart sequence.
    restart: ?bool = null,
};

pub const TerminateResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const BreakpointLocationsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        breakpointLocations,
    },
    arguments: ?BreakpointLocationsArguments = null,
};

/// Arguments for `breakpointLocations` request.
pub const BreakpointLocationsArguments = struct {
    /// The source location of the breakpoints; either `source.path` or `source.sourceReference` must be specified.
    source: Source,

    /// Start line of range to search possible breakpoint locations in. If only the line is specified, the request returns all possible locations in that line.
    line: i32,

    /// Start position within `line` to search possible breakpoint locations in. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based. If no column is given, the first position in the start line is assumed.
    column: ?i32 = null,

    /// End line of range to search possible breakpoint locations in. If no end line is given, then the end line is assumed to be the start line.
    endLine: ?i32 = null,

    /// End position within `endLine` to search possible breakpoint locations in. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based. If no end column is given, the last position in the end line is assumed.
    endColumn: ?i32 = null,
};

pub const BreakpointLocationsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// Sorted set of possible breakpoint locations.
        breakpoints: []BreakpointLocation,
    },
};

pub const SetBreakpointsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        setBreakpoints,
    },
    arguments: SetBreakpointsArguments,
};

/// Arguments for `setBreakpoints` request.
pub const SetBreakpointsArguments = struct {
    /// The source location of the breakpoints; either `source.path` or `source.sourceReference` must be specified.
    source: Source,

    /// The code locations of the breakpoints.
    breakpoints: ?[]SourceBreakpoint = null,

    /// Deprecated: The code locations of the breakpoints.
    lines: ?[]i32 = null,

    /// A value of true indicates that the underlying source has been modified which results in new breakpoint locations.
    sourceModified: ?bool = null,
};

pub const SetBreakpointsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// Information about the breakpoints.
        /// The array elements are in the same order as the elements of the `breakpoints` (or the deprecated `lines`) array in the arguments.
        breakpoints: []Breakpoint,
    },
};

pub const SetFunctionBreakpointsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        setFunctionBreakpoints,
    },
    arguments: SetFunctionBreakpointsArguments,
};

/// Arguments for `setFunctionBreakpoints` request.
pub const SetFunctionBreakpointsArguments = struct {
    /// The function names of the breakpoints.
    breakpoints: []FunctionBreakpoint,
};

pub const SetFunctionBreakpointsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// Information about the breakpoints. The array elements correspond to the elements of the `breakpoints` array.
        breakpoints: []Breakpoint,
    },
};

pub const SetExceptionBreakpointsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        setExceptionBreakpoints,
    },
    arguments: SetExceptionBreakpointsArguments,
};

/// Arguments for `setExceptionBreakpoints` request.
pub const SetExceptionBreakpointsArguments = struct {
    /// Set of exception filters specified by their ID. The set of all possible exception filters is defined by the `exceptionBreakpointFilters` capability. The `filter` and `filterOptions` sets are additive.
    filters: [][]const u8,

    /// Set of exception filters and their options. The set of all possible exception filters is defined by the `exceptionBreakpointFilters` capability. This attribute is only honored by a debug adapter if the corresponding capability `supportsExceptionFilterOptions` is true. The `filter` and `filterOptions` sets are additive.
    filterOptions: ?[]ExceptionFilterOptions = null,

    /// Configuration options for selected exceptions.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsExceptionOptions` is true.
    exceptionOptions: ?[]ExceptionOptions = null,
};

pub const SetExceptionBreakpointsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: ?struct {
        /// Information about the exception breakpoints or filters.
        /// The breakpoints returned are in the same order as the elements of the `filters`, `filterOptions`, `exceptionOptions` arrays in the arguments. If both `filters` and `filterOptions` are given, the returned array must start with `filters` information first, followed by `filterOptions` information.
        breakpoints: ?[]Breakpoint = null,
    } = null,
};

pub const DataBreakpointInfoRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        dataBreakpointInfo,
    },
    arguments: DataBreakpointInfoArguments,
};

/// Arguments for `dataBreakpointInfo` request.
pub const DataBreakpointInfoArguments = struct {
    /// Reference to the variable container if the data breakpoint is requested for a child of the container. The `variablesReference` must have been obtained in the current suspended state. See 'Lifetime of Object References' in the Overview section for details.
    variablesReference: ?i32 = null,

    /// The name of the variable's child to obtain data breakpoint information for.
    /// If `variablesReference` isn't specified, this can be an expression, or an address if `asAddress` is also true.
    name: []const u8,

    /// When `name` is an expression, evaluate it in the scope of this stack frame. If not specified, the expression is evaluated in the global scope. When `variablesReference` is specified, this property has no effect.
    frameId: ?i32 = null,

    /// If specified, a debug adapter should return information for the range of memory extending `bytes` number of bytes from the address or variable specified by `name`. Breakpoints set using the resulting data ID should pause on data access anywhere within that range.
    /// Clients may set this property only if the `supportsDataBreakpointBytes` capability is true.
    bytes: ?i32 = null,

    /// If `true`, the `name` is a memory address and the debugger should interpret it as a decimal value, or hex value if it is prefixed with `0x`.
    /// Clients may set this property only if the `supportsDataBreakpointBytes`
    /// capability is true.
    asAddress: ?bool = null,

    /// The mode of the desired breakpoint. If defined, this must be one of the `breakpointModes` the debug adapter advertised in its `Capabilities`.
    mode: ?[]const u8 = null,
};

pub const DataBreakpointInfoResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// An identifier for the data on which a data breakpoint can be registered with the `setDataBreakpoints` request or null if no data breakpoint is available. If a `variablesReference` or `frameId` is passed, the `dataId` is valid in the current suspended state, otherwise it's valid indefinitely. See 'Lifetime of Object References' in the Overview section for details. Breakpoints set using the `dataId` in the `setDataBreakpoints` request may outlive the lifetime of the associated `dataId`.
        dataId: union(enum) {
            pub usingnamespace UnionParser(@This());
            string: []const u8,
            null: void,
        },

        /// UI string that describes on what data the breakpoint is set on or why a data breakpoint is not available.
        description: []const u8,

        /// Attribute lists the available access types for a potential data breakpoint. A UI client could surface this information.
        accessTypes: ?[]DataBreakpointAccessType = null,

        /// Attribute indicates that a potential data breakpoint could be persisted across sessions.
        canPersist: ?bool = null,
    },
};

pub const SetDataBreakpointsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        setDataBreakpoints,
    },
    arguments: SetDataBreakpointsArguments,
};

/// Arguments for `setDataBreakpoints` request.
pub const SetDataBreakpointsArguments = struct {
    /// The contents of this array replaces all existing data breakpoints. An empty array clears all data breakpoints.
    breakpoints: []DataBreakpoint,
};

pub const SetDataBreakpointsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// Information about the data breakpoints. The array elements correspond to the elements of the input argument `breakpoints` array.
        breakpoints: []Breakpoint,
    },
};

pub const SetInstructionBreakpointsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        setInstructionBreakpoints,
    },
    arguments: SetInstructionBreakpointsArguments,
};

/// Arguments for `setInstructionBreakpoints` request
pub const SetInstructionBreakpointsArguments = struct {
    /// The instruction references of the breakpoints
    breakpoints: []InstructionBreakpoint,
};

pub const SetInstructionBreakpointsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// Information about the breakpoints. The array elements correspond to the elements of the `breakpoints` array.
        breakpoints: []Breakpoint,
    },
};

pub const ContinueRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        @"continue",
    },
    arguments: ContinueArguments,
};

/// Arguments for `continue` request.
pub const ContinueArguments = struct {
    /// Specifies the active thread. If the debug adapter supports single thread execution (see `supportsSingleThreadExecutionRequests`) and the argument `singleThread` is true, only the thread with this ID is resumed.
    threadId: i32,

    /// If this flag is true, execution is resumed only for the thread with given `threadId`.
    singleThread: ?bool = null,
};

pub const ContinueResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The value true (or a missing property) signals to the client that all threads have been resumed. The value false indicates that not all threads were resumed.
        allThreadsContinued: ?bool = null,
    },
};

pub const NextRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        next,
    },
    arguments: NextArguments,
};

/// Arguments for `next` request.
pub const NextArguments = struct {
    /// Specifies the thread for which to resume execution for one step (of the given granularity).
    threadId: i32,

    /// If this flag is true, all other suspended threads are not resumed.
    singleThread: ?bool = null,

    /// Stepping granularity. If no granularity is specified, a granularity of `statement` is assumed.
    granularity: ?SteppingGranularity = null,
};

pub const NextResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const StepInRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        stepIn,
    },
    arguments: StepInArguments,
};

/// Arguments for `stepIn` request.
pub const StepInArguments = struct {
    /// Specifies the thread for which to resume execution for one step-into (of the given granularity).
    threadId: i32,

    /// If this flag is true, all other suspended threads are not resumed.
    singleThread: ?bool = null,

    /// Id of the target to step into.
    targetId: ?i32 = null,

    /// Stepping granularity. If no granularity is specified, a granularity of `statement` is assumed.
    granularity: ?SteppingGranularity = null,
};

pub const StepInResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const StepOutRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        stepOut,
    },
    arguments: StepOutArguments,
};

/// Arguments for `stepOut` request.
pub const StepOutArguments = struct {
    /// Specifies the thread for which to resume execution for one step-out (of the given granularity).
    threadId: i32,

    /// If this flag is true, all other suspended threads are not resumed.
    singleThread: ?bool = null,

    /// Stepping granularity. If no granularity is specified, a granularity of `statement` is assumed.
    granularity: ?SteppingGranularity = null,
};

pub const StepOutResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const StepBackRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        stepBack,
    },
    arguments: StepBackArguments,
};

/// Arguments for `stepBack` request.
pub const StepBackArguments = struct {
    /// Specifies the thread for which to resume execution for one step backwards (of the given granularity).
    threadId: i32,

    /// If this flag is true, all other suspended threads are not resumed.
    singleThread: ?bool = null,

    /// Stepping granularity to step. If no granularity is specified, a granularity of `statement` is assumed.
    granularity: ?SteppingGranularity = null,
};

pub const StepBackResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const ReverseContinueRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        reverseContinue,
    },
    arguments: ReverseContinueArguments,
};

/// Arguments for `reverseContinue` request.
pub const ReverseContinueArguments = struct {
    /// Specifies the active thread. If the debug adapter supports single thread execution (see `supportsSingleThreadExecutionRequests`) and the `singleThread` argument is true, only the thread with this ID is resumed.
    threadId: i32,

    /// If this flag is true, backward execution is resumed only for the thread with given `threadId`.
    singleThread: ?bool = null,
};

pub const ReverseContinueResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const RestartFrameRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        restartFrame,
    },
    arguments: RestartFrameArguments,
};

/// Arguments for `restartFrame` request.
pub const RestartFrameArguments = struct {
    /// Restart the stack frame identified by `frameId`. The `frameId` must have been obtained in the current suspended state. See 'Lifetime of Object References' in the Overview section for details.
    frameId: i32,
};

pub const RestartFrameResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const GotoRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        goto,
    },
    arguments: GotoArguments,
};

/// Arguments for `goto` request.
pub const GotoArguments = struct {
    /// Set the goto target for this thread.
    threadId: i32,

    /// The location where the debuggee will continue to run.
    targetId: i32,
};

pub const GotoResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const PauseRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        pause,
    },
    arguments: PauseArguments,
};

/// Arguments for `pause` request.
pub const PauseArguments = struct {
    /// Pause execution for this thread.
    threadId: i32,
};

pub const PauseResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const StackTraceRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        stackTrace,
    },
    arguments: StackTraceArguments,
};

/// Arguments for `stackTrace` request.
pub const StackTraceArguments = struct {
    /// Retrieve the stacktrace for this thread.
    threadId: i32,

    /// The index of the first frame to return; if omitted frames start at 0.
    startFrame: ?i32 = null,

    /// The maximum number of frames to return. If levels is not specified or 0, all frames are returned.
    levels: ?i32 = null,

    /// Specifies details on how to format the stack frames.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsValueFormattingOptions` is true.
    format: ?StackFrameFormat = null,
};

pub const StackTraceResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The frames of the stack frame. If the array has length zero, there are no stack frames available.
        /// This means that there is no location information available.
        stackFrames: []StackFrame,

        /// The total number of frames available in the stack. If omitted or if `totalFrames` is larger than the available frames, a client is expected to request frames until a request returns less frames than requested (which indicates the end of the stack). Returning monotonically increasing `totalFrames` values for subsequent requests can be used to enforce paging in the client.
        totalFrames: ?i32 = null,
    },
};

pub const ScopesRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        scopes,
    },
    arguments: ScopesArguments,
};

/// Arguments for `scopes` request.
pub const ScopesArguments = struct {
    /// Retrieve the scopes for the stack frame identified by `frameId`. The `frameId` must have been obtained in the current suspended state. See 'Lifetime of Object References' in the Overview section for details.
    frameId: i32,
};

pub const ScopesResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The scopes of the stack frame. If the array has length zero, there are no scopes available.
        scopes: []Scope,
    },
};

pub const VariablesRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        variables,
    },
    arguments: VariablesArguments,
};

/// Arguments for `variables` request.
pub const VariablesArguments = struct {
    /// The variable for which to retrieve its children. The `variablesReference` must have been obtained in the current suspended state. See 'Lifetime of Object References' in the Overview section for details.
    variablesReference: i32,

    /// Filter to limit the child variables to either named or indexed. If omitted, both types are fetched.
    filter: ?enum {
        pub usingnamespace EnumParser(@This());
        indexed,
        named,
    } = null,

    /// The index of the first variable to return; if omitted children start at 0.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsVariablePaging` is true.
    start: ?i32 = null,

    /// The number of variables to return. If count is missing or 0, all variables are returned.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsVariablePaging` is true.
    count: ?i32 = null,

    /// Specifies details on how to format the Variable values.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsValueFormattingOptions` is true.
    format: ?ValueFormat = null,
};

pub const VariablesResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// All (or a range) of variables for the given variable reference.
        variables: []Variable,
    },
};

pub const SetVariableRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        setVariable,
    },
    arguments: SetVariableArguments,
};

/// Arguments for `setVariable` request.
pub const SetVariableArguments = struct {
    /// The reference of the variable container. The `variablesReference` must have been obtained in the current suspended state. See 'Lifetime of Object References' in the Overview section for details.
    variablesReference: i32,

    /// The name of the variable in the container.
    name: []const u8,

    /// The value of the variable.
    value: []const u8,

    /// Specifies details on how to format the response value.
    format: ?ValueFormat = null,
};

pub const SetVariableResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The new value of the variable.
        value: []const u8,

        /// The type of the new value. Typically shown in the UI when hovering over the value.
        type: ?[]const u8 = null,

        /// If `variablesReference` is > 0, the new value is structured and its children can be retrieved by passing `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
        /// If this property is included in the response, any `variablesReference` previously associated with the updated variable, and those of its children, are no longer valid.
        variablesReference: ?i32 = null,

        /// The number of named child variables.
        /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
        /// The value should be less than or equal to 2147483647 (2^31-1).
        namedVariables: ?i32 = null,

        /// The number of indexed child variables.
        /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
        /// The value should be less than or equal to 2147483647 (2^31-1).
        indexedVariables: ?i32 = null,

        /// A memory reference to a location appropriate for this result.
        /// For pointer type eval results, this is generally a reference to the memory address contained in the pointer.
        /// This attribute may be returned by a debug adapter if corresponding capability `supportsMemoryReferences` is true.
        memoryReference: ?[]const u8 = null,

        /// A reference that allows the client to request the location where the new value is declared. For example, if the new value is function pointer, the adapter may be able to look up the function's location. This should be present only if the adapter is likely to be able to resolve the location.
        /// This reference shares the same lifetime as the `variablesReference`. See 'Lifetime of Object References' in the Overview section for details.
        valueLocationReference: ?i32 = null,
    },
};

pub const SourceRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        source,
    },
    arguments: SourceArguments,
};

/// Arguments for `source` request.
pub const SourceArguments = struct {
    /// Specifies the source content to load. Either `source.path` or `source.sourceReference` must be specified.
    source: ?Source = null,

    /// The reference to the source. This is the same as `source.sourceReference`.
    /// This is provided for backward compatibility since old clients do not understand the `source` attribute.
    sourceReference: i32,
};

pub const SourceResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// Content of the source reference.
        content: []const u8,

        /// Content type (MIME type) of the source.
        mimeType: ?[]const u8 = null,
    },
};

pub const ThreadsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        threads,
    },

    /// Object containing arguments for the command.
    arguments: ?Value = null,
};

pub const ThreadsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// All threads.
        threads: []Thread,
    },
};

pub const TerminateThreadsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        terminateThreads,
    },
    arguments: TerminateThreadsArguments,
};

/// Arguments for `terminateThreads` request.
pub const TerminateThreadsArguments = struct {
    /// Ids of threads to be terminated.
    threadIds: ?[]i32 = null,
};

pub const TerminateThreadsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,

    /// Contains request result if success is true and error details if success is false.
    body: ?Value = null,
};

pub const ModulesRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        modules,
    },
    arguments: ModulesArguments,
};

/// Arguments for `modules` request.
pub const ModulesArguments = struct {
    /// The index of the first module to return; if omitted modules start at 0.
    startModule: ?i32 = null,

    /// The number of modules to return. If `moduleCount` is not specified or 0, all modules are returned.
    moduleCount: ?i32 = null,
};

pub const ModulesResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// All modules or range of modules.
        modules: []Module,

        /// The total number of modules available.
        totalModules: ?i32 = null,
    },
};

pub const LoadedSourcesRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        loadedSources,
    },
    arguments: ?LoadedSourcesArguments = null,
};

/// Arguments for `loadedSources` request.
pub const LoadedSourcesArguments = struct { map: Object };

pub const LoadedSourcesResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// Set of loaded sources.
        sources: []Source,
    },
};

pub const EvaluateRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        evaluate,
    },
    arguments: EvaluateArguments,
};

/// Arguments for `evaluate` request.
pub const EvaluateArguments = struct {
    /// The expression to evaluate.
    expression: []const u8,

    /// Evaluate the expression in the scope of this stack frame. If not specified, the expression is evaluated in the global scope.
    frameId: ?i32 = null,

    /// The contextual line where the expression should be evaluated. In the 'hover' context, this should be set to the start of the expression being hovered.
    line: ?i32 = null,

    /// The contextual column where the expression should be evaluated. This may be provided if `line` is also provided.
    /// It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?i32 = null,

    /// The contextual source in which the `line` is found. This must be provided if `line` is provided.
    source: ?Source = null,

    /// The context in which the evaluate request is used.
    context: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// evaluate is called from a watch view context.
        watch,
        /// evaluate is called from a REPL context.
        repl,
        /// evaluate is called to generate the debug hover contents.
        /// This value should only be used if the corresponding capability `supportsEvaluateForHovers` is true.
        hover,
        /// evaluate is called to generate clipboard contents.
        /// This value should only be used if the corresponding capability `supportsClipboardContext` is true.
        clipboard,
        /// evaluate is called from a variables view context.
        variables,
        string: []const u8,
    } = null,

    /// Specifies details on how to format the result.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsValueFormattingOptions` is true.
    format: ?ValueFormat = null,
};

pub const EvaluateResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The result of the evaluate request.
        result: []const u8,

        /// The type of the evaluate result.
        /// This attribute should only be returned by a debug adapter if the corresponding capability `supportsVariableType` is true.
        type: ?[]const u8 = null,

        /// Properties of an evaluate result that can be used to determine how to render the result in the UI.
        presentationHint: ?VariablePresentationHint = null,

        /// If `variablesReference` is > 0, the evaluate result is structured and its children can be retrieved by passing `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
        variablesReference: i32,

        /// The number of named child variables.
        /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
        /// The value should be less than or equal to 2147483647 (2^31-1).
        namedVariables: ?i32 = null,

        /// The number of indexed child variables.
        /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
        /// The value should be less than or equal to 2147483647 (2^31-1).
        indexedVariables: ?i32 = null,

        /// A memory reference to a location appropriate for this result.
        /// For pointer type eval results, this is generally a reference to the memory address contained in the pointer.
        /// This attribute may be returned by a debug adapter if corresponding capability `supportsMemoryReferences` is true.
        memoryReference: ?[]const u8 = null,

        /// A reference that allows the client to request the location where the returned value is declared. For example, if a function pointer is returned, the adapter may be able to look up the function's location. This should be present only if the adapter is likely to be able to resolve the location.
        /// This reference shares the same lifetime as the `variablesReference`. See 'Lifetime of Object References' in the Overview section for details.
        valueLocationReference: ?i32 = null,
    },
};

pub const SetExpressionRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        setExpression,
    },
    arguments: SetExpressionArguments,
};

/// Arguments for `setExpression` request.
pub const SetExpressionArguments = struct {
    /// The l-value expression to assign to.
    expression: []const u8,

    /// The value expression to assign to the l-value expression.
    value: []const u8,

    /// Evaluate the expressions in the scope of this stack frame. If not specified, the expressions are evaluated in the global scope.
    frameId: ?i32 = null,

    /// Specifies how the resulting value should be formatted.
    format: ?ValueFormat = null,
};

pub const SetExpressionResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The new value of the expression.
        value: []const u8,

        /// The type of the value.
        /// This attribute should only be returned by a debug adapter if the corresponding capability `supportsVariableType` is true.
        type: ?[]const u8 = null,

        /// Properties of a value that can be used to determine how to render the result in the UI.
        presentationHint: ?VariablePresentationHint = null,

        /// If `variablesReference` is > 0, the evaluate result is structured and its children can be retrieved by passing `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
        variablesReference: ?i32 = null,

        /// The number of named child variables.
        /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
        /// The value should be less than or equal to 2147483647 (2^31-1).
        namedVariables: ?i32 = null,

        /// The number of indexed child variables.
        /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
        /// The value should be less than or equal to 2147483647 (2^31-1).
        indexedVariables: ?i32 = null,

        /// A memory reference to a location appropriate for this result.
        /// For pointer type eval results, this is generally a reference to the memory address contained in the pointer.
        /// This attribute may be returned by a debug adapter if corresponding capability `supportsMemoryReferences` is true.
        memoryReference: ?[]const u8 = null,

        /// A reference that allows the client to request the location where the new value is declared. For example, if the new value is function pointer, the adapter may be able to look up the function's location. This should be present only if the adapter is likely to be able to resolve the location.
        /// This reference shares the same lifetime as the `variablesReference`. See 'Lifetime of Object References' in the Overview section for details.
        valueLocationReference: ?i32 = null,
    },
};

pub const StepInTargetsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        stepInTargets,
    },
    arguments: StepInTargetsArguments,
};

/// Arguments for `stepInTargets` request.
pub const StepInTargetsArguments = struct {
    /// The stack frame for which to retrieve the possible step-in targets.
    frameId: i32,
};

pub const StepInTargetsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The possible step-in targets of the specified source location.
        targets: []StepInTarget,
    },
};

pub const GotoTargetsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        gotoTargets,
    },
    arguments: GotoTargetsArguments,
};

/// Arguments for `gotoTargets` request.
pub const GotoTargetsArguments = struct {
    /// The source location for which the goto targets are determined.
    source: Source,

    /// The line location for which the goto targets are determined.
    line: i32,

    /// The position within `line` for which the goto targets are determined. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?i32 = null,
};

pub const GotoTargetsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The possible goto targets of the specified location.
        targets: []GotoTarget,
    },
};

pub const CompletionsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        completions,
    },
    arguments: CompletionsArguments,
};

/// Arguments for `completions` request.
pub const CompletionsArguments = struct {
    /// Returns completions in the scope of this stack frame. If not specified, the completions are returned for the global scope.
    frameId: ?i32 = null,

    /// One or more source lines. Typically this is the text users have typed into the debug console before they asked for completion.
    text: []const u8,

    /// The position within `text` for which to determine the completion proposals. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: i32,

    /// A line for which to determine the completion proposals. If missing the first line of the text is assumed.
    line: ?i32 = null,
};

pub const CompletionsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// The possible completions for .
        targets: []CompletionItem,
    },
};

pub const ExceptionInfoRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        exceptionInfo,
    },
    arguments: ExceptionInfoArguments,
};

/// Arguments for `exceptionInfo` request.
pub const ExceptionInfoArguments = struct {
    /// Thread for which exception information should be retrieved.
    threadId: i32,
};

pub const ExceptionInfoResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: struct {
        /// ID of the exception that was thrown.
        exceptionId: []const u8,

        /// Descriptive text for the exception.
        description: ?[]const u8 = null,

        /// Mode that caused the exception notification to be raised.
        breakMode: ExceptionBreakMode,

        /// Detailed information about the exception.
        details: ?ExceptionDetails = null,
    },
};

pub const ReadMemoryRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        readMemory,
    },
    arguments: ReadMemoryArguments,
};

/// Arguments for `readMemory` request.
pub const ReadMemoryArguments = struct {
    /// Memory reference to the base location from which data should be read.
    memoryReference: []const u8,

    /// Offset (in bytes) to be applied to the reference location before reading data. Can be negative.
    offset: ?i32 = null,

    /// Number of bytes to read at the specified location and offset.
    count: i32,
};

pub const ReadMemoryResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: ?struct {
        /// The address of the first byte of data returned.
        /// Treated as a hex value if prefixed with `0x`, or as a decimal value otherwise.
        address: []const u8,

        /// The number of unreadable bytes encountered after the last successfully read byte.
        /// This can be used to determine the number of bytes that should be skipped before a subsequent `readMemory` request succeeds.
        unreadableBytes: ?i32 = null,

        /// The bytes read from memory, encoded using base64. If the decoded length of `data` is less than the requested `count` in the original `readMemory` request, and `unreadableBytes` is zero or omitted, then the client should assume it's reached the end of readable memory.
        data: ?[]const u8 = null,
    } = null,
};

pub const WriteMemoryRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        writeMemory,
    },
    arguments: WriteMemoryArguments,
};

/// Arguments for `writeMemory` request.
pub const WriteMemoryArguments = struct {
    /// Memory reference to the base location to which data should be written.
    memoryReference: []const u8,

    /// Offset (in bytes) to be applied to the reference location before writing data. Can be negative.
    offset: ?i32 = null,

    /// Property to control partial writes. If true, the debug adapter should attempt to write memory even if the entire memory region is not writable. In such a case the debug adapter should stop after hitting the first byte of memory that cannot be written and return the number of bytes written in the response via the `offset` and `bytesWritten` properties.
    /// If false or missing, a debug adapter should attempt to verify the region is writable before writing, and fail the response if it is not.
    allowPartial: ?bool = null,

    /// Bytes to write, encoded using base64.
    data: []const u8,
};

pub const WriteMemoryResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: ?struct {
        /// Property that should be returned when `allowPartial` is true to indicate the offset of the first byte of data successfully written. Can be negative.
        offset: ?i32 = null,

        /// Property that should be returned when `allowPartial` is true to indicate the number of bytes starting from address that were successfully written.
        bytesWritten: ?i32 = null,
    } = null,
};

pub const DisassembleRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        disassemble,
    },
    arguments: DisassembleArguments,
};

/// Arguments for `disassemble` request.
pub const DisassembleArguments = struct {
    /// Memory reference to the base location containing the instructions to disassemble.
    memoryReference: []const u8,

    /// Offset (in bytes) to be applied to the reference location before disassembling. Can be negative.
    offset: ?i32 = null,

    /// Offset (in instructions) to be applied after the byte offset (if any) before disassembling. Can be negative.
    instructionOffset: ?i32 = null,

    /// Number of instructions to disassemble starting at the specified location and offset.
    /// An adapter must return exactly this number of instructions - any unavailable instructions should be replaced with an implementation-defined 'invalid instruction' value.
    instructionCount: i32,

    /// If true, the adapter should attempt to resolve memory addresses and other values to symbolic names.
    resolveSymbols: ?bool = null,
};

pub const DisassembleResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: ?struct {
        /// The list of disassembled instructions.
        instructions: []DisassembledInstruction,
    } = null,
};

pub const LocationsRequest = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        request,
    },
    command: enum {
        pub usingnamespace EnumParser(@This());
        locations,
    },
    arguments: LocationsArguments,
};

/// Arguments for `locations` request.
pub const LocationsArguments = struct {
    /// Location reference to resolve.
    locationReference: i32,
};

pub const LocationsResponse = struct {
    /// Sequence number of the message (also known as message ID). The `seq` for the first message sent by a client or debug adapter is 1, and for each subsequent message is 1 greater than the previous message sent by that actor. `seq` can be used to order requests, responses, and events, and to associate requests with their corresponding responses. For protocol messages of type `request` the sequence number can be used to cancel the request.
    seq: i32,
    type: enum {
        pub usingnamespace EnumParser(@This());
        response,
    },

    /// Sequence number of the corresponding request.
    request_seq: i32,

    /// Outcome of the request.
    /// If true, the request was successful and the `body` attribute may contain the result of the request.
    /// If the value is false, the attribute `message` contains the error in short form and the `body` may contain additional information (see `ErrorResponse.body.error`).
    success: bool,

    /// The command requested.
    command: []const u8,

    /// Contains the raw error in short form if `success` is false.
    /// This raw error might be interpreted by the client and is not shown in the UI.
    /// Some predefined values exist.
    message: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// the request was cancelled.
        cancelled,
        /// the request may be retried once the adapter is in a 'stopped' state.
        notStopped,
        string: []const u8,
    } = null,
    body: ?struct {
        /// The source containing the location; either `source.path` or `source.sourceReference` must be specified.
        source: Source,

        /// The line number of the location. The client capability `linesStartAt1` determines whether it is 0- or 1-based.
        line: i32,

        /// Position of the location within the `line`. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based. If no column is given, the first position in the start line is assumed.
        column: ?i32 = null,

        /// End line of the location, present if the location refers to a range.  The client capability `linesStartAt1` determines whether it is 0- or 1-based.
        endLine: ?i32 = null,

        /// End position of the location within `endLine`, present if the location refers to a range. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
        endColumn: ?i32 = null,
    } = null,
};

/// Information about the capabilities of a debug adapter.
pub const Capabilities = struct {
    /// The debug adapter supports the `configurationDone` request.
    supportsConfigurationDoneRequest: ?bool = null,

    /// The debug adapter supports function breakpoints.
    supportsFunctionBreakpoints: ?bool = null,

    /// The debug adapter supports conditional breakpoints.
    supportsConditionalBreakpoints: ?bool = null,

    /// The debug adapter supports breakpoints that break execution after a specified number of hits.
    supportsHitConditionalBreakpoints: ?bool = null,

    /// The debug adapter supports a (side effect free) `evaluate` request for data hovers.
    supportsEvaluateForHovers: ?bool = null,

    /// Available exception filter options for the `setExceptionBreakpoints` request.
    exceptionBreakpointFilters: ?[]ExceptionBreakpointsFilter = null,

    /// The debug adapter supports stepping back via the `stepBack` and `reverseContinue` requests.
    supportsStepBack: ?bool = null,

    /// The debug adapter supports setting a variable to a value.
    supportsSetVariable: ?bool = null,

    /// The debug adapter supports restarting a frame.
    supportsRestartFrame: ?bool = null,

    /// The debug adapter supports the `gotoTargets` request.
    supportsGotoTargetsRequest: ?bool = null,

    /// The debug adapter supports the `stepInTargets` request.
    supportsStepInTargetsRequest: ?bool = null,

    /// The debug adapter supports the `completions` request.
    supportsCompletionsRequest: ?bool = null,

    /// The set of characters that should trigger completion in a REPL. If not specified, the UI should assume the `.` character.
    completionTriggerCharacters: ?[][]const u8 = null,

    /// The debug adapter supports the `modules` request.
    supportsModulesRequest: ?bool = null,

    /// The set of additional module information exposed by the debug adapter.
    additionalModuleColumns: ?[]ColumnDescriptor = null,

    /// Checksum algorithms supported by the debug adapter.
    supportedChecksumAlgorithms: ?[]ChecksumAlgorithm = null,

    /// The debug adapter supports the `restart` request. In this case a client should not implement `restart` by terminating and relaunching the adapter but by calling the `restart` request.
    supportsRestartRequest: ?bool = null,

    /// The debug adapter supports `exceptionOptions` on the `setExceptionBreakpoints` request.
    supportsExceptionOptions: ?bool = null,

    /// The debug adapter supports a `format` attribute on the `stackTrace`, `variables`, and `evaluate` requests.
    supportsValueFormattingOptions: ?bool = null,

    /// The debug adapter supports the `exceptionInfo` request.
    supportsExceptionInfoRequest: ?bool = null,

    /// The debug adapter supports the `terminateDebuggee` attribute on the `disconnect` request.
    supportTerminateDebuggee: ?bool = null,

    /// The debug adapter supports the `suspendDebuggee` attribute on the `disconnect` request.
    supportSuspendDebuggee: ?bool = null,

    /// The debug adapter supports the delayed loading of parts of the stack, which requires that both the `startFrame` and `levels` arguments and the `totalFrames` result of the `stackTrace` request are supported.
    supportsDelayedStackTraceLoading: ?bool = null,

    /// The debug adapter supports the `loadedSources` request.
    supportsLoadedSourcesRequest: ?bool = null,

    /// The debug adapter supports log points by interpreting the `logMessage` attribute of the `SourceBreakpoint`.
    supportsLogPoints: ?bool = null,

    /// The debug adapter supports the `terminateThreads` request.
    supportsTerminateThreadsRequest: ?bool = null,

    /// The debug adapter supports the `setExpression` request.
    supportsSetExpression: ?bool = null,

    /// The debug adapter supports the `terminate` request.
    supportsTerminateRequest: ?bool = null,

    /// The debug adapter supports data breakpoints.
    supportsDataBreakpoints: ?bool = null,

    /// The debug adapter supports the `readMemory` request.
    supportsReadMemoryRequest: ?bool = null,

    /// The debug adapter supports the `writeMemory` request.
    supportsWriteMemoryRequest: ?bool = null,

    /// The debug adapter supports the `disassemble` request.
    supportsDisassembleRequest: ?bool = null,

    /// The debug adapter supports the `cancel` request.
    supportsCancelRequest: ?bool = null,

    /// The debug adapter supports the `breakpointLocations` request.
    supportsBreakpointLocationsRequest: ?bool = null,

    /// The debug adapter supports the `clipboard` context value in the `evaluate` request.
    supportsClipboardContext: ?bool = null,

    /// The debug adapter supports stepping granularities (argument `granularity`) for the stepping requests.
    supportsSteppingGranularity: ?bool = null,

    /// The debug adapter supports adding breakpoints based on instruction references.
    supportsInstructionBreakpoints: ?bool = null,

    /// The debug adapter supports `filterOptions` as an argument on the `setExceptionBreakpoints` request.
    supportsExceptionFilterOptions: ?bool = null,

    /// The debug adapter supports the `singleThread` property on the execution requests (`continue`, `next`, `stepIn`, `stepOut`, `reverseContinue`, `stepBack`).
    supportsSingleThreadExecutionRequests: ?bool = null,

    /// The debug adapter supports the `asAddress` and `bytes` fields in the `dataBreakpointInfo` request.
    supportsDataBreakpointBytes: ?bool = null,

    /// Modes of breakpoints supported by the debug adapter, such as 'hardware' or 'software'. If present, the client may allow the user to select a mode and include it in its `setBreakpoints` request.
    /// Clients may present the first applicable mode in this array as the 'default' mode in gestures that set breakpoints.
    breakpointModes: ?[]BreakpointMode = null,

    /// The debug adapter supports ANSI escape sequences in styling of `OutputEvent.output` and `Variable.value` fields.
    supportsANSIStyling: ?bool = null,
};

/// An `ExceptionBreakpointsFilter` is shown in the UI as an filter option for configuring how exceptions are dealt with.
pub const ExceptionBreakpointsFilter = struct {
    /// The internal ID of the filter option. This value is passed to the `setExceptionBreakpoints` request.
    filter: []const u8,

    /// The name of the filter option. This is shown in the UI.
    label: []const u8,

    /// A help text providing additional information about the exception filter. This string is typically shown as a hover and can be translated.
    description: ?[]const u8 = null,

    /// Initial value of the filter option. If not specified a value false is assumed.
    default: ?bool = null,

    /// Controls whether a condition can be specified for this filter option. If false or missing, a condition can not be set.
    supportsCondition: ?bool = null,

    /// A help text providing information about the condition. This string is shown as the placeholder text for a text box and can be translated.
    conditionDescription: ?[]const u8 = null,
};

/// A structured message object. Used to return errors from requests.
pub const Message = struct {
    /// Unique (within a debug adapter implementation) identifier for the message. The purpose of these error IDs is to help extension authors that have the requirement that every user visible error message needs a corresponding error number, so that users or customer support can find information about the specific error more easily.
    id: i32,

    /// A format string for the message. Embedded variables have the form `{name}`.
    /// If variable name starts with an underscore character, the variable does not contain user data (PII) and can be safely used for telemetry purposes.
    format: []const u8,

    /// An object used as a dictionary for looking up the variables in the format string.
    variables: ?struct {
        pub const additional_properties: AdditionalProperties = &.{
            .string,
        };
        map: Object,
    } = null,

    /// If true send to telemetry.
    sendTelemetry: ?bool = null,

    /// If true show user.
    showUser: ?bool = null,

    /// A url where additional information about this message can be found.
    url: ?[]const u8 = null,

    /// A label that is presented to the user as the UI for opening the url.
    urlLabel: ?[]const u8 = null,
};

/// A Module object represents a row in the modules view.
/// The `id` attribute identifies a module in the modules view and is used in a `module` event for identifying a module for adding, updating or deleting.
/// The `name` attribute is used to minimally render the module in the UI.
/// Additional attributes can be added to the module. They show up in the module view if they have a corresponding `ColumnDescriptor`.
/// To avoid an unnecessary proliferation of additional attributes with similar semantics but different names, we recommend to re-use attributes from the 'recommended' list below first, and only introduce new attributes if nothing appropriate could be found.
pub const Module = struct {
    /// Unique identifier for the module.
    id: union(enum) {
        pub usingnamespace UnionParser(@This());
        integer: i32,
        string: []const u8,
    },

    /// A name of the module.
    name: []const u8,

    /// Logical full path to the module. The exact definition is implementation defined, but usually this would be a full path to the on-disk file for the module.
    path: ?[]const u8 = null,

    /// True if the module is optimized.
    isOptimized: ?bool = null,

    /// True if the module is considered 'user code' by a debugger that supports 'Just My Code'.
    isUserCode: ?bool = null,

    /// Version of Module.
    version: ?[]const u8 = null,

    /// User-understandable description of if symbols were found for the module (ex: 'Symbols Loaded', 'Symbols not found', etc.)
    symbolStatus: ?[]const u8 = null,

    /// Logical full path to the symbol file. The exact definition is implementation defined.
    symbolFilePath: ?[]const u8 = null,

    /// Module created or modified, encoded as a RFC 3339 timestamp.
    dateTimeStamp: ?[]const u8 = null,

    /// Address range covered by this module.
    addressRange: ?[]const u8 = null,
};

/// A `ColumnDescriptor` specifies what module attribute to show in a column of the modules view, how to format it,
/// and what the column's label should be.
/// It is only used if the underlying UI actually supports this level of customization.
pub const ColumnDescriptor = struct {
    /// Name of the attribute rendered in this column.
    attributeName: []const u8,

    /// Header UI label of column.
    label: []const u8,

    /// Format to use for the rendered values in this column. TBD how the format strings looks like.
    format: ?[]const u8 = null,

    /// Datatype of values in this column. Defaults to `string` if not specified.
    type: ?enum {
        pub usingnamespace EnumParser(@This());
        string,
        number,
        boolean,
        unixTimestampUTC,
    } = null,

    /// Width of this column in characters (hint only).
    width: ?i32 = null,
};

/// A Thread
pub const Thread = struct {
    /// Unique identifier for the thread.
    id: i32,

    /// The name of the thread.
    name: []const u8,
};

/// A `Source` is a descriptor for source code.
/// It is returned from the debug adapter as part of a `StackFrame` and it is used by clients when specifying breakpoints.
pub const Source = struct {
    /// The short name of the source. Every source returned from the debug adapter has a name.
    /// When sending a source to the debug adapter this name is optional.
    name: ?[]const u8 = null,

    /// The path of the source to be shown in the UI.
    /// It is only used to locate and load the content of the source if no `sourceReference` is specified (or its value is 0).
    path: ?[]const u8 = null,

    /// If the value > 0 the contents of the source must be retrieved through the `source` request (even if a path is specified).
    /// Since a `sourceReference` is only valid for a session, it can not be used to persist a source.
    /// The value should be less than or equal to 2147483647 (2^31-1).
    sourceReference: ?i32 = null,

    /// A hint for how to present the source in the UI.
    /// A value of `deemphasize` can be used to indicate that the source is not available or that it is skipped on stepping.
    presentationHint: ?enum {
        pub usingnamespace EnumParser(@This());
        normal,
        emphasize,
        deemphasize,
    } = null,

    /// The origin of this source. For example, 'internal module', 'inlined content from source map', etc.
    origin: ?[]const u8 = null,

    /// A list of sources that are related to this source. These may be the source that generated this source.
    sources: ?[]Source = null,

    /// Additional data that a debug adapter might want to loop through the client.
    /// The client should leave the data intact and persist it across sessions. The client should not interpret the data.
    adapterData: ?Value = null,

    /// The checksums associated with this file.
    checksums: ?[]Checksum = null,
};

/// A Stackframe contains the source location.
pub const StackFrame = struct {
    /// An identifier for the stack frame. It must be unique across all threads.
    /// This id can be used to retrieve the scopes of the frame with the `scopes` request or to restart the execution of a stack frame.
    id: i32,

    /// The name of the stack frame, typically a method name.
    name: []const u8,

    /// The source of the frame.
    source: ?Source = null,

    /// The line within the source of the frame. If the source attribute is missing or doesn't exist, `line` is 0 and should be ignored by the client.
    line: i32,

    /// Start position of the range covered by the stack frame. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based. If attribute `source` is missing or doesn't exist, `column` is 0 and should be ignored by the client.
    column: i32,

    /// The end line of the range covered by the stack frame.
    endLine: ?i32 = null,

    /// End position of the range covered by the stack frame. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    endColumn: ?i32 = null,

    /// Indicates whether this frame can be restarted with the `restartFrame` request. Clients should only use this if the debug adapter supports the `restart` request and the corresponding capability `supportsRestartFrame` is true. If a debug adapter has this capability, then `canRestart` defaults to `true` if the property is absent.
    canRestart: ?bool = null,

    /// A memory reference for the current instruction pointer in this frame.
    instructionPointerReference: ?[]const u8 = null,

    /// The module associated with this frame, if any.
    moduleId: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        integer: i32,
        string: []const u8,
    } = null,

    /// A hint for how to present this frame in the UI.
    /// A value of `label` can be used to indicate that the frame is an artificial frame that is used as a visual label or separator. A value of `subtle` can be used to change the appearance of a frame in a 'subtle' way.
    presentationHint: ?enum {
        pub usingnamespace EnumParser(@This());
        normal,
        label,
        subtle,
    } = null,
};

/// A `Scope` is a named container for variables. Optionally a scope can map to a source or a range within a source.
pub const Scope = struct {
    /// Name of the scope such as 'Arguments', 'Locals', or 'Registers'. This string is shown in the UI as is and can be translated.
    name: []const u8,

    /// A hint for how to present this scope in the UI. If this attribute is missing, the scope is shown with a generic UI.
    presentationHint: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// Scope contains method arguments.
        arguments,
        /// Scope contains local variables.
        locals,
        /// Scope contains registers. Only a single `registers` scope should be returned from a `scopes` request.
        registers,
        /// Scope contains one or more return values.
        returnValue,
        string: []const u8,
    } = null,

    /// The variables of this scope can be retrieved by passing the value of `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
    variablesReference: i32,

    /// The number of named variables in this scope.
    /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
    namedVariables: ?i32 = null,

    /// The number of indexed variables in this scope.
    /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
    indexedVariables: ?i32 = null,

    /// If true, the number of variables in this scope is large or expensive to retrieve.
    expensive: bool,

    /// The source for this scope.
    source: ?Source = null,

    /// The start line of the range covered by this scope.
    line: ?i32 = null,

    /// Start position of the range covered by the scope. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?i32 = null,

    /// The end line of the range covered by this scope.
    endLine: ?i32 = null,

    /// End position of the range covered by the scope. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    endColumn: ?i32 = null,
};

/// A Variable is a name/value pair.
/// The `type` attribute is shown if space permits or when hovering over the variable's name.
/// The `kind` attribute is used to render additional properties of the variable, e.g. different icons can be used to indicate that a variable is public or private.
/// If the value is structured (has children), a handle is provided to retrieve the children with the `variables` request.
/// If the number of named or indexed children is large, the numbers should be returned via the `namedVariables` and `indexedVariables` attributes.
/// The client can use this information to present the children in a paged UI and fetch them in chunks.
pub const Variable = struct {
    /// The variable's name.
    name: []const u8,

    /// The variable's value.
    /// This can be a multi-line text, e.g. for a function the body of a function.
    /// For structured variables (which do not have a simple value), it is recommended to provide a one-line representation of the structured object. This helps to identify the structured object in the collapsed state when its children are not yet visible.
    /// An empty string can be used if no value should be shown in the UI.
    value: []const u8,

    /// The type of the variable's value. Typically shown in the UI when hovering over the value.
    /// This attribute should only be returned by a debug adapter if the corresponding capability `supportsVariableType` is true.
    type: ?[]const u8 = null,

    /// Properties of a variable that can be used to determine how to render the variable in the UI.
    presentationHint: ?VariablePresentationHint = null,

    /// The evaluatable name of this variable which can be passed to the `evaluate` request to fetch the variable's value.
    evaluateName: ?[]const u8 = null,

    /// If `variablesReference` is > 0, the variable is structured and its children can be retrieved by passing `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
    variablesReference: i32,

    /// The number of named child variables.
    /// The client can use this information to present the children in a paged UI and fetch them in chunks.
    namedVariables: ?i32 = null,

    /// The number of indexed child variables.
    /// The client can use this information to present the children in a paged UI and fetch them in chunks.
    indexedVariables: ?i32 = null,

    /// A memory reference associated with this variable.
    /// For pointer type variables, this is generally a reference to the memory address contained in the pointer.
    /// For executable data, this reference may later be used in a `disassemble` request.
    /// This attribute may be returned by a debug adapter if corresponding capability `supportsMemoryReferences` is true.
    memoryReference: ?[]const u8 = null,

    /// A reference that allows the client to request the location where the variable is declared. This should be present only if the adapter is likely to be able to resolve the location.
    /// This reference shares the same lifetime as the `variablesReference`. See 'Lifetime of Object References' in the Overview section for details.
    declarationLocationReference: ?i32 = null,

    /// A reference that allows the client to request the location where the variable's value is declared. For example, if the variable contains a function pointer, the adapter may be able to look up the function's location. This should be present only if the adapter is likely to be able to resolve the location.
    /// This reference shares the same lifetime as the `variablesReference`. See 'Lifetime of Object References' in the Overview section for details.
    valueLocationReference: ?i32 = null,
};

/// Properties of a variable that can be used to determine how to render the variable in the UI.
pub const VariablePresentationHint = struct {
    /// The kind of variable. Before introducing additional values, try to use the listed values.
    kind: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        /// Indicates that the object is a property.
        property,
        /// Indicates that the object is a method.
        method,
        /// Indicates that the object is a class.
        class,
        /// Indicates that the object is data.
        data,
        /// Indicates that the object is an event.
        event,
        /// Indicates that the object is a base class.
        baseClass,
        /// Indicates that the object is an inner class.
        innerClass,
        /// Indicates that the object is an interface.
        interface,
        /// Indicates that the object is the most derived class.
        mostDerivedClass,
        /// Indicates that the object is virtual, that means it is a synthetic object introduced by the adapter for rendering purposes, e.g. an index range for large arrays.
        virtual,
        /// Deprecated: Indicates that a data breakpoint is registered for the object. The `hasDataBreakpoint` attribute should generally be used instead.
        dataBreakpoint,
        string: []const u8,
    } = null,

    /// Set of attributes represented as an array of strings. Before introducing additional values, try to use the listed values.
    attributes: ?[]union(enum) {
        pub usingnamespace UnionParser(@This());
        /// Indicates that the object is static.
        static,
        /// Indicates that the object is a constant.
        constant,
        /// Indicates that the object is read only.
        readOnly,
        /// Indicates that the object is a raw string.
        rawString,
        /// Indicates that the object can have an Object ID created for it. This is a vestigial attribute that is used by some clients; 'Object ID's are not specified in the protocol.
        hasObjectId,
        /// Indicates that the object has an Object ID associated with it. This is a vestigial attribute that is used by some clients; 'Object ID's are not specified in the protocol.
        canHaveObjectId,
        /// Indicates that the evaluation had side effects.
        hasSideEffects,
        /// Indicates that the object has its value tracked by a data breakpoint.
        hasDataBreakpoint,
        string: []const u8,
    } = null,

    /// Visibility of variable. Before introducing additional values, try to use the listed values.
    visibility: ?union(enum) {
        pub usingnamespace UnionParser(@This());
        public,
        private,
        protected,
        internal,
        final,
        string: []const u8,
    } = null,

    /// If true, clients can present the variable with a UI that supports a specific gesture to trigger its evaluation.
    /// This mechanism can be used for properties that require executing code when retrieving their value and where the code execution can be expensive and/or produce side-effects. A typical example are properties based on a getter function.
    /// Please note that in addition to the `lazy` flag, the variable's `variablesReference` is expected to refer to a variable that will provide the value through another `variable` request.
    lazy: ?bool = null,
};

/// Properties of a breakpoint location returned from the `breakpointLocations` request.
pub const BreakpointLocation = struct {
    /// Start line of breakpoint location.
    line: i32,

    /// The start position of a breakpoint location. Position is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?i32 = null,

    /// The end line of breakpoint location if the location covers a range.
    endLine: ?i32 = null,

    /// The end position of a breakpoint location (if the location covers a range). Position is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    endColumn: ?i32 = null,
};

/// Properties of a breakpoint or logpoint passed to the `setBreakpoints` request.
pub const SourceBreakpoint = struct {
    /// The source line of the breakpoint or logpoint.
    line: i32,

    /// Start position within source line of the breakpoint or logpoint. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?i32 = null,

    /// The expression for conditional breakpoints.
    /// It is only honored by a debug adapter if the corresponding capability `supportsConditionalBreakpoints` is true.
    condition: ?[]const u8 = null,

    /// The expression that controls how many hits of the breakpoint are ignored.
    /// The debug adapter is expected to interpret the expression as needed.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsHitConditionalBreakpoints` is true.
    /// If both this property and `condition` are specified, `hitCondition` should be evaluated only if the `condition` is met, and the debug adapter should stop only if both conditions are met.
    hitCondition: ?[]const u8 = null,

    /// If this attribute exists and is non-empty, the debug adapter must not 'break' (stop)
    /// but log the message instead. Expressions within `{}` are interpolated.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsLogPoints` is true.
    /// If either `hitCondition` or `condition` is specified, then the message should only be logged if those conditions are met.
    logMessage: ?[]const u8 = null,

    /// The mode of this breakpoint. If defined, this must be one of the `breakpointModes` the debug adapter advertised in its `Capabilities`.
    mode: ?[]const u8 = null,
};

/// Properties of a breakpoint passed to the `setFunctionBreakpoints` request.
pub const FunctionBreakpoint = struct {
    /// The name of the function.
    name: []const u8,

    /// An expression for conditional breakpoints.
    /// It is only honored by a debug adapter if the corresponding capability `supportsConditionalBreakpoints` is true.
    condition: ?[]const u8 = null,

    /// An expression that controls how many hits of the breakpoint are ignored.
    /// The debug adapter is expected to interpret the expression as needed.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsHitConditionalBreakpoints` is true.
    hitCondition: ?[]const u8 = null,
};

/// This enumeration defines all possible access types for data breakpoints.
pub const DataBreakpointAccessType = enum {
    pub usingnamespace EnumParser(@This());
    read,
    write,
    readWrite,
};

/// Properties of a data breakpoint passed to the `setDataBreakpoints` request.
pub const DataBreakpoint = struct {
    /// An id representing the data. This id is returned from the `dataBreakpointInfo` request.
    dataId: []const u8,

    /// The access type of the data.
    accessType: ?DataBreakpointAccessType = null,

    /// An expression for conditional breakpoints.
    condition: ?[]const u8 = null,

    /// An expression that controls how many hits of the breakpoint are ignored.
    /// The debug adapter is expected to interpret the expression as needed.
    hitCondition: ?[]const u8 = null,
};

/// Properties of a breakpoint passed to the `setInstructionBreakpoints` request
pub const InstructionBreakpoint = struct {
    /// The instruction reference of the breakpoint.
    /// This should be a memory or instruction pointer reference from an `EvaluateResponse`, `Variable`, `StackFrame`, `GotoTarget`, or `Breakpoint`.
    instructionReference: []const u8,

    /// The offset from the instruction reference in bytes.
    /// This can be negative.
    offset: ?i32 = null,

    /// An expression for conditional breakpoints.
    /// It is only honored by a debug adapter if the corresponding capability `supportsConditionalBreakpoints` is true.
    condition: ?[]const u8 = null,

    /// An expression that controls how many hits of the breakpoint are ignored.
    /// The debug adapter is expected to interpret the expression as needed.
    /// The attribute is only honored by a debug adapter if the corresponding capability `supportsHitConditionalBreakpoints` is true.
    hitCondition: ?[]const u8 = null,

    /// The mode of this breakpoint. If defined, this must be one of the `breakpointModes` the debug adapter advertised in its `Capabilities`.
    mode: ?[]const u8 = null,
};

/// Information about a breakpoint created in `setBreakpoints`, `setFunctionBreakpoints`, `setInstructionBreakpoints`, or `setDataBreakpoints` requests.
pub const Breakpoint = struct {
    /// The identifier for the breakpoint. It is needed if breakpoint events are used to update or remove breakpoints.
    id: ?i32 = null,

    /// If true, the breakpoint could be set (but not necessarily at the desired location).
    verified: bool,

    /// A message about the state of the breakpoint.
    /// This is shown to the user and can be used to explain why a breakpoint could not be verified.
    message: ?[]const u8 = null,

    /// The source where the breakpoint is located.
    source: ?Source = null,

    /// The start line of the actual range covered by the breakpoint.
    line: ?i32 = null,

    /// Start position of the source range covered by the breakpoint. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?i32 = null,

    /// The end line of the actual range covered by the breakpoint.
    endLine: ?i32 = null,

    /// End position of the source range covered by the breakpoint. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    /// If no end line is given, then the end column is assumed to be in the start line.
    endColumn: ?i32 = null,

    /// A memory reference to where the breakpoint is set.
    instructionReference: ?[]const u8 = null,

    /// The offset from the instruction reference.
    /// This can be negative.
    offset: ?i32 = null,

    /// A machine-readable explanation of why a breakpoint may not be verified. If a breakpoint is verified or a specific reason is not known, the adapter should omit this property. Possible values include:
    /// - `pending`: Indicates a breakpoint might be verified in the future, but the adapter cannot verify it in the current state.
    ///  - `failed`: Indicates a breakpoint was not able to be verified, and the adapter does not believe it can be verified without intervention.
    reason: ?enum {
        pub usingnamespace EnumParser(@This());
        pending,
        failed,
    } = null,
};

/// The granularity of one 'step' in the stepping requests `next`, `stepIn`, `stepOut`, and `stepBack`.
pub const SteppingGranularity = enum {
    pub usingnamespace EnumParser(@This());
    /// The step should allow the program to run until the current statement has finished executing.
    /// The meaning of a statement is determined by the adapter and it may be considered equivalent to a line.
    /// For example 'for(int i = 0; i < 10; i++)' could be considered to have 3 statements 'int i = 0', 'i < 10', and 'i++'.
    statement,
    /// The step should allow the program to run until the current source line has executed.
    line,
    /// The step should allow one instruction to execute (e.g. one x86 instruction).
    instruction,
};

/// A `StepInTarget` can be used in the `stepIn` request and determines into which single target the `stepIn` request should step.
pub const StepInTarget = struct {
    /// Unique identifier for a step-in target.
    id: i32,

    /// The name of the step-in target (shown in the UI).
    label: []const u8,

    /// The line of the step-in target.
    line: ?i32 = null,

    /// Start position of the range covered by the step in target. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?i32 = null,

    /// The end line of the range covered by the step-in target.
    endLine: ?i32 = null,

    /// End position of the range covered by the step in target. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    endColumn: ?i32 = null,
};

/// A `GotoTarget` describes a code location that can be used as a target in the `goto` request.
/// The possible goto targets can be determined via the `gotoTargets` request.
pub const GotoTarget = struct {
    /// Unique identifier for a goto target. This is used in the `goto` request.
    id: i32,

    /// The name of the goto target (shown in the UI).
    label: []const u8,

    /// The line of the goto target.
    line: i32,

    /// The column of the goto target.
    column: ?i32 = null,

    /// The end line of the range covered by the goto target.
    endLine: ?i32 = null,

    /// The end column of the range covered by the goto target.
    endColumn: ?i32 = null,

    /// A memory reference for the instruction pointer value represented by this target.
    instructionPointerReference: ?[]const u8 = null,
};

/// `CompletionItems` are the suggestions returned from the `completions` request.
pub const CompletionItem = struct {
    /// The label of this completion item. By default this is also the text that is inserted when selecting this completion.
    label: []const u8,

    /// If text is returned and not an empty string, then it is inserted instead of the label.
    text: ?[]const u8 = null,

    /// A string that should be used when comparing this item with other items. If not returned or an empty string, the `label` is used instead.
    sortText: ?[]const u8 = null,

    /// A human-readable string with additional information about this item, like type or symbol information.
    detail: ?[]const u8 = null,

    /// The item's type. Typically the client uses this information to render the item in the UI with an icon.
    type: ?CompletionItemType = null,

    /// Start position (within the `text` attribute of the `completions` request) where the completion text is added. The position is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based. If the start position is omitted the text is added at the location specified by the `column` attribute of the `completions` request.
    start: ?i32 = null,

    /// Length determines how many characters are overwritten by the completion text and it is measured in UTF-16 code units. If missing the value 0 is assumed which results in the completion text being inserted.
    length: ?i32 = null,

    /// Determines the start of the new selection after the text has been inserted (or replaced). `selectionStart` is measured in UTF-16 code units and must be in the range 0 and length of the completion text. If omitted the selection starts at the end of the completion text.
    selectionStart: ?i32 = null,

    /// Determines the length of the new selection after the text has been inserted (or replaced) and it is measured in UTF-16 code units. The selection can not extend beyond the bounds of the completion text. If omitted the length is assumed to be 0.
    selectionLength: ?i32 = null,
};

/// Some predefined types for the CompletionItem. Please note that not all clients have specific icons for all of them.
pub const CompletionItemType = enum {
    pub usingnamespace EnumParser(@This());
    method,
    function,
    constructor,
    field,
    variable,
    class,
    interface,
    module,
    property,
    unit,
    value,
    @"enum",
    keyword,
    snippet,
    text,
    color,
    file,
    reference,
    customcolor,
};

/// Names of checksum algorithms that may be supported by a debug adapter.
pub const ChecksumAlgorithm = enum {
    pub usingnamespace EnumParser(@This());
    MD5,
    SHA1,
    SHA256,
    timestamp,
};

/// The checksum of an item calculated by the specified algorithm.
pub const Checksum = struct {
    /// The algorithm used to calculate this checksum.
    algorithm: ChecksumAlgorithm,

    /// Value of the checksum, encoded as a hexadecimal value.
    checksum: []const u8,
};

/// Provides formatting information for a value.
pub const ValueFormat = struct {
    /// Display the value in hex.
    hex: ?bool = null,
};

pub const StackFrameFormat = struct {
    /// Display the value in hex.
    hex: ?bool = null,

    /// Displays parameters for the stack frame.
    parameters: ?bool = null,

    /// Displays the types of parameters for the stack frame.
    parameterTypes: ?bool = null,

    /// Displays the names of parameters for the stack frame.
    parameterNames: ?bool = null,

    /// Displays the values of parameters for the stack frame.
    parameterValues: ?bool = null,

    /// Displays the line number of the stack frame.
    line: ?bool = null,

    /// Displays the module of the stack frame.
    module: ?bool = null,

    /// Includes all stack frames, including those the debug adapter might otherwise hide.
    includeAll: ?bool = null,
};

/// An `ExceptionFilterOptions` is used to specify an exception filter together with a condition for the `setExceptionBreakpoints` request.
pub const ExceptionFilterOptions = struct {
    /// ID of an exception filter returned by the `exceptionBreakpointFilters` capability.
    filterId: []const u8,

    /// An expression for conditional exceptions.
    /// The exception breaks into the debugger if the result of the condition is true.
    condition: ?[]const u8 = null,

    /// The mode of this exception breakpoint. If defined, this must be one of the `breakpointModes` the debug adapter advertised in its `Capabilities`.
    mode: ?[]const u8 = null,
};

/// An `ExceptionOptions` assigns configuration options to a set of exceptions.
pub const ExceptionOptions = struct {
    /// A path that selects a single or multiple exceptions in a tree. If `path` is missing, the whole tree is selected.
    /// By convention the first segment of the path is a category that is used to group exceptions in the UI.
    path: ?[]ExceptionPathSegment = null,

    /// Condition when a thrown exception should result in a break.
    breakMode: ExceptionBreakMode,
};

/// This enumeration defines all possible conditions when a thrown exception should result in a break.
/// never: never breaks,
/// always: always breaks,
/// unhandled: breaks when exception unhandled,
/// userUnhandled: breaks if the exception is not handled by user code.
pub const ExceptionBreakMode = enum {
    pub usingnamespace EnumParser(@This());
    never,
    always,
    unhandled,
    userUnhandled,
};

/// An `ExceptionPathSegment` represents a segment in a path that is used to match leafs or nodes in a tree of exceptions.
/// If a segment consists of more than one name, it matches the names provided if `negate` is false or missing, or it matches anything except the names provided if `negate` is true.
pub const ExceptionPathSegment = struct {
    /// If false or missing this segment matches the names provided, otherwise it matches anything except the names provided.
    negate: ?bool = null,

    /// Depending on the value of `negate` the names that should match or not match.
    names: [][]const u8,
};

/// Detailed information about an exception that has occurred.
pub const ExceptionDetails = struct {
    /// Message contained in the exception.
    message: ?[]const u8 = null,

    /// Short type name of the exception object.
    typeName: ?[]const u8 = null,

    /// Fully-qualified type name of the exception object.
    fullTypeName: ?[]const u8 = null,

    /// An expression that can be evaluated in the current scope to obtain the exception object.
    evaluateName: ?[]const u8 = null,

    /// Stack trace at the time the exception was thrown.
    stackTrace: ?[]const u8 = null,

    /// Details of the exception contained by this exception, if any.
    innerException: ?[]ExceptionDetails = null,
};

/// Represents a single disassembled instruction.
pub const DisassembledInstruction = struct {
    /// The address of the instruction. Treated as a hex value if prefixed with `0x`, or as a decimal value otherwise.
    address: []const u8,

    /// Raw bytes representing the instruction and its operands, in an implementation-defined format.
    instructionBytes: ?[]const u8 = null,

    /// Text representing the instruction and its operands, in an implementation-defined format.
    instruction: []const u8,

    /// Name of the symbol that corresponds with the location of this instruction, if any.
    symbol: ?[]const u8 = null,

    /// Source location that corresponds to this instruction, if any.
    /// Should always be set (if available) on the first instruction returned,
    /// but can be omitted afterwards if this instruction maps to the same source file as the previous instruction.
    location: ?Source = null,

    /// The line within the source location that corresponds to this instruction, if any.
    line: ?i32 = null,

    /// The column within the line that corresponds to this instruction, if any.
    column: ?i32 = null,

    /// The end line of the range that corresponds to this instruction, if any.
    endLine: ?i32 = null,

    /// The end column of the range that corresponds to this instruction, if any.
    endColumn: ?i32 = null,

    /// A hint for how to present the instruction in the UI.
    /// A value of `invalid` may be used to indicate this instruction is 'filler' and cannot be reached by the program. For example, unreadable memory addresses may be presented is 'invalid.'
    presentationHint: ?enum {
        pub usingnamespace EnumParser(@This());
        normal,
        invalid,
    } = null,
};

/// Logical areas that can be invalidated by the `invalidated` event.
pub const InvalidatedAreas = union(enum) {
    pub usingnamespace UnionParser(@This());
    /// All previously fetched data has become invalid and needs to be refetched.
    all,
    /// Previously fetched stack related data has become invalid and needs to be refetched.
    stacks,
    /// Previously fetched thread related data has become invalid and needs to be refetched.
    threads,
    /// Previously fetched variable data has become invalid and needs to be refetched.
    variables,
    string: []const u8,
};

/// A `BreakpointMode` is provided as a option when setting breakpoints on sources or instructions.
pub const BreakpointMode = struct {
    /// The internal ID of the mode. This value is passed to the `setBreakpoints` request.
    mode: []const u8,

    /// The name of the breakpoint mode. This is shown in the UI.
    label: []const u8,

    /// A help text providing additional information about the breakpoint mode. This string is typically shown as a hover and can be translated.
    description: ?[]const u8 = null,

    /// Describes one or more type of breakpoint this mode applies to.
    appliesTo: []BreakpointModeApplicability,
};

/// Describes one or more type of breakpoint a `BreakpointMode` applies to. This is a non-exhaustive enumeration and may expand as future breakpoint types are added.
pub const BreakpointModeApplicability = union(enum) {
    pub usingnamespace UnionParser(@This());
    /// In `SourceBreakpoint`s
    source,
    /// In exception breakpoints applied in the `ExceptionFilterOptions`
    exception,
    /// In data breakpoints requested in the `DataBreakpointInfo` request
    data,
    /// In `InstructionBreakpoint`s
    instruction,
    string: []const u8,
};
