; The uploaded Swift grammar represents class, struct, enum, actor, and extension
; declarations with `class_declaration`, selecting different anonymous keywords.
(class_declaration body: (class_body) @fold)
(class_declaration body: (enum_class_body) @fold)
(protocol_declaration body: (protocol_body) @fold)
(function_declaration body: (function_body) @fold)
(lambda_literal) @fold
(if_statement) @fold
(switch_statement) @fold
(for_statement) @fold
(while_statement) @fold
(do_statement) @fold
(array_literal) @fold
(dictionary_literal) @fold
(multi_line_string_literal) @fold
(comment) @fold
(multiline_comment) @fold
