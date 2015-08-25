/**** rfc822-parser.c ****/

#ifndef RFC822_PARSER_H
#define RFC822_PARSER_H

struct rfc822_parser_context {
	const unsigned char *data, *end;
	string_t *last_comment;
};

#define IS_ATEXT(c) \
	(rfc822_atext_chars[(int)(unsigned char)(c)] != 0)
#define IS_ATEXT_NON_TSPECIAL(c) \
	((rfc822_atext_chars[(int)(unsigned char)(c)] & 3) != 0)
extern unsigned char rfc822_atext_chars[256];

/* Parse given data using RFC 822 token parser. */
void rfc822_parser_init(struct rfc822_parser_context *ctx,
			const unsigned char *data, size_t size,
			string_t *last_comment) ATTR_NULL(4);

/* The functions below return 1 = more data available, 0 = no more data
   available (but a value might have been returned now), -1 = invalid input.

   LWSP is automatically skipped after value, but not before it. So typically
   you begin with skipping LWSP and then start using the parse functions. */

/* Parse comment. Assumes parser's data points to '(' */
int rfc822_skip_comment(struct rfc822_parser_context *ctx);
/* Skip LWSP if there is any */
int ATTR_NOWARN_UNUSED_RESULT
rfc822_skip_lwsp(struct rfc822_parser_context *ctx);
/* Stop at next non-atext char */
int rfc822_parse_atom(struct rfc822_parser_context *ctx, string_t *str);
/* Like parse_atom() but don't stop at '.' */
int rfc822_parse_dot_atom(struct rfc822_parser_context *ctx, string_t *str);
/* Like parse_dot_atom() but stops for '/', '?' and '='.
   Also it doesn't allow LWSP around '.' chars. */
int rfc822_parse_mime_token(struct rfc822_parser_context *ctx, string_t *str);
/* "quoted string" */
int rfc822_parse_quoted_string(struct rfc822_parser_context *ctx,
			       string_t *str);
/* atom or quoted-string */
int rfc822_parse_phrase(struct rfc822_parser_context *ctx, string_t *str);
/* dot-atom / domain-literal */
int rfc822_parse_domain(struct rfc822_parser_context *ctx, string_t *str);

/* Parse Content-Type header's type/subtype. */
int rfc822_parse_content_type(struct rfc822_parser_context *ctx, string_t *str);
/* For Content-Type style parameter parsing. Expect ";" key "=" value.
   value is unescaped if needed. The returned strings are allocated from data
   stack. Returns 1 = key/value set, 0 = no more data, -1 = invalid input. */
int rfc822_parse_content_param(struct rfc822_parser_context *ctx,
			       const char **key_r, const char **value_r);

#endif

/**** message-address.h ****/

#ifndef MESSAGE_ADDRESS_H
#define MESSAGE_ADDRESS_H

/* group: ... ; will be stored like:
   {name = NULL, NULL, "group", NULL}, ..., {NULL, NULL, NULL, NULL}
*/
struct message_address {
	struct message_address *next;

	/* display-name */
	const char *name;
	/* route string contains the @ prefix */
	const char *route;
	/* local-part */
	const char *mailbox;
	const char *domain;
	/* there were errors when parsing this address */
	bool invalid_syntax;
};

/* Parse message addresses from given data. If fill_missing is TRUE, missing
   mailbox and domain are set to MISSING_MAILBOX and MISSING_DOMAIN strings.
   Otherwise they're set to "".

   Note that giving an empty string will return NULL since there are no
   addresses. */
struct message_address *
message_address_parse(pool_t pool, const unsigned char *data, size_t size,
		      unsigned int max_addresses, bool fill_missing);

void message_address_write(string_t *str, const struct message_address *addr);

/* Returns TRUE if header is known to be an address */
bool message_header_is_address(const char *hdr_name);

#endif
