/* Copyright (c) 2015-2016 by Pali <pali@cpan.org> */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "dovecot-parser.h"

/* Exported i_panic function for other C files */
void i_panic(const char *format, ...)
{
	va_list args;

	va_start(args, format);
	vcroak(format, &args);
	va_end(args);
}

static void append_carp_shortmess(SV *scalar)
{
	dSP;
	int count;

	ENTER;
	SAVETMPS;
	PUSHMARK(SP);

	count = call_pv("Carp::shortmess", G_SCALAR);

	SPAGAIN;

	if (count > 0)
		sv_catsv(scalar, POPs);

	PUTBACK;
	FREETMPS;
	LEAVE;
}

#define CARP_WARN false
#define CARP_DIE true
static void carp(bool fatal, const char *format, ...)
{
	va_list args;
	SV *scalar;

	va_start(args, format);
	scalar = vnewSVpvf(format, &args);
	va_end(args);

	append_carp_shortmess(scalar);

	if (!fatal)
		warn_sv(scalar);
	else
		croak_sv(scalar);

	SvREFCNT_dec(scalar);
}

static const char *get_perl_scalar_value(SV *scalar, bool utf8)
{
	const char *string;

	if (!SvOK(scalar))
		return NULL;

	string = SvPV_nolen(scalar);
	if (utf8 && !SvUTF8(scalar))
		return SvPVutf8_nolen(sv_mortalcopy(scalar));

	return string;
}

static const char *get_perl_scalar_string_value(SV *scalar, const char *name)
{
	const char *string;

	string = get_perl_scalar_value(scalar, false);
	if (!string) {
		carp(CARP_WARN, "Use of uninitialized value for %s", name);
		return "";
	}

	return string;
}

static SV *get_perl_hash_scalar(HV *hash, const char *key)
{
	I32 klen;
	SV **scalar_ptr;

	klen = strlen(key);

	if (!hv_exists(hash, key, klen))
		return NULL;

	scalar_ptr = hv_fetch(hash, key, klen, 0);
	if (!scalar_ptr)
		return NULL;

	return *scalar_ptr;
}

static const char *get_perl_hash_value(HV *hash, const char *key, bool utf8)
{
	SV *scalar;

	scalar = get_perl_hash_scalar(hash, key);
	if (!scalar)
		return NULL;

	return get_perl_scalar_value(scalar, utf8);
}

static void set_perl_hash_value(HV *hash, const char *key, const char *value, bool utf8)
{
	I32 klen;
	SV *scalar;

	klen = strlen(key);

	if (value)
		scalar = newSVpv(value, 0);
	else
		scalar = newSV(0);

	if (utf8 && value)
		sv_utf8_decode(scalar);

	hv_store(hash, key, klen, scalar, 0);
}

static HV *get_perl_class_from_perl_cv(CV *cv)
{
	GV *gv;
	HV *class;

	class = NULL;
	gv = CvGV(cv);

	if (gv)
		class = GvSTASH(gv);

	if (!class)
		class = CvSTASH(cv);

	if (!class)
		class = PL_curstash;

	if (!class)
		carp(CARP_DIE, "Cannot retrieve class");

	return class;
}

static HV *get_perl_class_from_perl_scalar(SV *scalar)
{
	HV *class;
	const char *class_name;

	class_name = get_perl_scalar_string_value(scalar, "class");

	if (!class_name[0]) {
		carp(CARP_WARN, "Explicit blessing to '' (assuming package main)");
		class_name = "main";
	}

	class = gv_stashpv(class_name, GV_ADD);
	if (!class)
		carp(CARP_DIE, "Cannot retrieve class %s", class_name);

	return class;
}

static HV *get_perl_class_from_perl_scalar_or_cv(SV *scalar, CV *cv)
{
	if (scalar)
		return get_perl_class_from_perl_scalar(scalar);
	else
		return get_perl_class_from_perl_cv(cv);
}

static bool is_class_object(const char *class, SV *object)
{
	return sv_isobject(object) && sv_derived_from(object, class);
}

static HV* get_object_hash_from_perl_array(AV *array, I32 index1, I32 index2, const char *class, bool warn)
{
	SV *scalar;
	SV *object;
	SV **object_ptr;

	object_ptr = av_fetch(array, index2, 0);
	if (!object_ptr) {
		if (warn)
			carp(CARP_WARN, "Element at index %d/%d is NULL", (int)index1, (int)index2);
		return NULL;
	}

	object = *object_ptr;
	if (!is_class_object(class, object)) {
		if (warn)
			carp(CARP_WARN, "Element at index %d/%d is not %s object", (int)index1, (int)index2, class);
		return NULL;
	}

	if (!SvROK(object)) {
		if (warn)
			carp(CARP_WARN, "Element at index %d/%d is not reference", (int)index1, (int)index2);
		return NULL;
	}

	scalar = SvRV(object);
	if (SvTYPE(scalar) != SVt_PVHV) {
		if (warn)
			carp(CARP_WARN, "Element at index %d/%d is not HASH reference", (int)index1, (int)index2);
		return NULL;
	}

	return (HV *)scalar;

}

static void message_address_add_from_perl_array(struct message_address **first_address, struct message_address **last_address, bool utf8, AV *array, I32 index1, I32 index2, const char *class)
{
	HV *hash;
	const char *name;
	const char *mailbox;
	const char *domain;
	const char *comment;

	hash = get_object_hash_from_perl_array(array, index1, index2, class, false);
	if (!hash)
		return;

	name = get_perl_hash_value(hash, "phrase", utf8);
	mailbox = get_perl_hash_value(hash, "user", utf8);
	domain = get_perl_hash_value(hash, "host", utf8);
	comment = get_perl_hash_value(hash, "comment", utf8);

	if (mailbox && !mailbox[0])
		mailbox = NULL;

	if (domain && !domain[0])
		domain = NULL;

	if (!mailbox && !domain) {
		carp(CARP_WARN, "Element at index %d/%d contains empty address", (int)index1, (int)index2);
		return;
	}

	if (!mailbox) {
		carp(CARP_WARN, "Element at index %d/%d contains empty user portion of address", (int)index1, (int)index2);
		mailbox = "";
	}

	if (!domain) {
		carp(CARP_WARN, "Element at index %d/%d contains empty host portion of address", (int)index1, (int)index2);
		domain = "";
	}

	message_address_add(first_address, last_address, name, NULL, mailbox, domain, comment);
}

static AV *get_perl_array_from_scalar(SV *scalar, const char *group_name, bool warn)
{
	SV *scalar_ref;

	if (!SvOK(scalar))
		return NULL;

	if (scalar && !SvROK(scalar)) {
		if (warn)
			carp(CARP_WARN, "Value for group '%s' is not reference", group_name);
		return NULL;
	}

	scalar_ref = SvRV(scalar);

	if (!scalar_ref || SvTYPE(scalar_ref) != SVt_PVAV) {
		if (warn)
			carp(CARP_WARN, "Value for group '%s' is not ARRAY reference", group_name);
		return NULL;
	}

	return (AV *)scalar_ref;
}

static void message_address_add_from_perl_group(struct message_address **first_address, struct message_address **last_address, bool utf8, SV *scalar_group, SV *scalar_list, I32 index1, const char *class)
{
	I32 len;
	I32 index2;
	AV *array;
	const char *group_name;

	group_name = get_perl_scalar_value(scalar_group, utf8);
	array = get_perl_array_from_scalar(scalar_list, group_name, false);
	len = array ? (av_len(array) + 1) : 0;

	if (group_name)
		message_address_add(first_address, last_address, NULL, NULL, group_name, NULL, NULL);

	for (index2 = 0; index2 < len; ++index2)
		message_address_add_from_perl_array(first_address, last_address, utf8, array, index1, index2, class);

	if (group_name)
		message_address_add(first_address, last_address, NULL, NULL, NULL, NULL, NULL);
}

static bool perl_group_needs_utf8(SV *scalar_group, SV *scalar_list, I32 index1, const char *class)
{
	I32 len;
	I32 index2;
	SV *scalar;
	HV *hash;
	AV *array;
	const char *group_name;
	const char **hash_key_ptr;

	static const char *hash_keys[] = { "phrase", "user", "host", "comment", NULL };

	group_name = get_perl_scalar_value(scalar_group, false);
	if (SvUTF8(scalar_group))
		return true;

	array = get_perl_array_from_scalar(scalar_list, group_name, true);
	len = array ? (av_len(array) + 1) : 0;

	for (index2 = 0; index2 < len; ++index2) {
		hash = get_object_hash_from_perl_array(array, index1, index2, class, true);
		if (!hash)
			continue;
		for (hash_key_ptr = hash_keys; *hash_key_ptr; ++hash_key_ptr) {
			scalar = get_perl_hash_scalar(hash, *hash_key_ptr);
			if (scalar && get_perl_scalar_value(scalar, false) && SvUTF8(scalar))
				return true;
		}
	}

	return false;
}

static int count_address_groups(struct message_address *first_address)
{
	int count;
	bool in_group;
	struct message_address *address;

	count = 0;
	in_group = false;

	for (address = first_address; address; address = address->next) {
		if (!address->domain)
			in_group = !in_group;
		if (in_group)
			continue;
		++count;
	}

	return count;
}

static bool get_next_perl_address_group(struct message_address **address, SV **group_scalar, SV **addresses_scalar, HV *class, bool utf8)
{
	HV *hash;
	SV *object;
	SV *hash_ref;
	bool in_group;
	AV *addresses_array;

	if (!*address)
		return false;

	in_group = !(*address)->domain;

	if (in_group && (*address)->mailbox)
		*group_scalar = newSVpv((*address)->mailbox, 0);
	else
		*group_scalar = newSV(0);

	if (utf8 && in_group && (*address)->mailbox)
		sv_utf8_decode(*group_scalar);

	addresses_array = newAV();
	*addresses_scalar = newRV_noinc((SV *)addresses_array);

	if (in_group)
		*address = (*address)->next;

	while (*address && (*address)->domain) {
		hash = newHV();

		set_perl_hash_value(hash, "phrase", (*address)->name, utf8);
		set_perl_hash_value(hash, "user", ( (*address)->mailbox && (*address)->mailbox[0] ) ? (*address)->mailbox : NULL, utf8);
		set_perl_hash_value(hash, "host", ( (*address)->domain && (*address)->domain[0] ) ? (*address)->domain : NULL, utf8);
		set_perl_hash_value(hash, "comment", (*address)->comment, utf8);

		hash_ref = newRV_noinc((SV *)hash);
		object = sv_bless(hash_ref, class);

		av_push(addresses_array, object);

		*address = (*address)->next;
	}

	if (in_group && *address)
		*address = (*address)->next;

	return true;
}


MODULE = Email::Address::XS		PACKAGE = Email::Address::XS		

PROTOTYPES: DISABLE

SV *
format_email_groups(...)
PREINIT:
	I32 i;
	bool utf8;
	char *string;
	struct message_address *first_address;
	struct message_address *last_address;
INPUT:
	const char *this_class_name = "$Package";
INIT:
	if (items % 2 == 1) {
		carp(CARP_WARN, "Odd number of elements in argument list");
		XSRETURN_UNDEF;
	}
CODE:
	utf8 = false;
	first_address = NULL;
	last_address = NULL;
	for (i = 0; i < items; i += 2)
		if ((utf8 = perl_group_needs_utf8(ST(i), ST(i+1), i, this_class_name)))
			break;
	for (i = 0; i < items; i += 2)
		message_address_add_from_perl_group(&first_address, &last_address, utf8, ST(i), ST(i+1), i, this_class_name);
	message_address_write(&string, first_address);
	message_address_free(&first_address);
	RETVAL = newSVpv(string, 0);
	if (utf8)
		sv_utf8_decode(RETVAL);
	free(string);
OUTPUT:
	RETVAL

void
parse_email_groups(string, class = NO_INIT)
	SV *string
	SV *class
PREINIT:
	int count;
	HV *hv_class;
	SV *group_scalar;
	SV *addresses_scalar;
	bool utf8;
	const char *input;
	const char *class_name;
	struct message_address *address;
	struct message_address *first_address;
INPUT:
	const char *this_class_name = "$Package";
INIT:
	input = get_perl_scalar_string_value(string, "string");
	utf8 = SvUTF8(string);
	hv_class = get_perl_class_from_perl_scalar_or_cv(items >= 2 ? class : NULL, cv);
	if (items >= 2 && !sv_derived_from(class, this_class_name)) {
		class_name = HvNAME(hv_class);
		carp(CARP_WARN, "Class %s is not derived from %s", (class_name ? class_name : "(unknown)"), this_class_name);
		XSRETURN_EMPTY;
	}
PPCODE:
	first_address = message_address_parse(input, UINT_MAX, false);
	count = count_address_groups(first_address);
	EXTEND(SP, count * 2);
	address = first_address;
	while (get_next_perl_address_group(&address, &group_scalar, &addresses_scalar, hv_class, utf8)) {
		PUSHs(sv_2mortal(group_scalar));
		PUSHs(sv_2mortal(addresses_scalar));
	}
	message_address_free(&first_address);

void
compose_address(OUTLIST string, mailbox, domain)
	char *string
	const char *mailbox
	const char *domain
CLEANUP:
	free(string);

void
split_address(string, OUTLIST mailbox, OUTLIST domain)
	const char *string
	char *mailbox
	char *domain
CLEANUP:
	free(mailbox);
	free(domain);

void
is_obj(class, object)
	const char *class
	SV *object
CODE:
	is_class_object(class, object) ? XSRETURN_YES : XSRETURN_NO;
