/* Copyright (c) 2015-2017 by Pali <pali@cpan.org> */

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "dovecot-parser.h"

/* Perl pre 5.6.1 support */
#if PERL_VERSION < 6 || (PERL_VERSION == 6 && PERL_SUBVERSION < 1)
#define BROKEN_SvPVutf8
#endif

/* Perl pre 5.7.2 support */
#ifndef SvPV_nomg
#define WITHOUT_SvPV_nomg
#endif

/* Perl pre 5.8.0 support */
#ifndef UTF8_IS_INVARIANT
#define UTF8_IS_INVARIANT(c) (((U8)c) < 0x80)
#endif

/* Perl pre 5.10.1 support */
#ifndef newSVpvn_utf8
static SV *newSVpvn_utf8(pTHX_ const char *str, STRLEN len, U32 utf8) {
	SV *sv = newSVpvn(str, len);
	if (utf8) SvUTF8_on(sv);
	return sv;
}
#define newSVpvn_utf8(str, len, utf8) newSVpvn_utf8(aTHX_ str, len, utf8)
#endif

/* Perl pre 5.13.1 support */
#ifndef warn_sv
#define warn_sv(scalar) warn("%s", SvPV_nolen(scalar))
#endif
#ifndef croak_sv
#define croak_sv(scalar) croak("%s", SvPV_nolen(scalar))
#endif

/* Perl pre 5.15.4 support */
#ifndef sv_derived_from_pvn
#define sv_derived_from_pvn(scalar, name, len, flags) sv_derived_from(scalar, name)
#endif

/* Exported i_panic function for other C files */
void i_panic(const char *format, ...)
{
	dTHX;
	va_list args;

	va_start(args, format);
	vcroak(format, &args);
	va_end(args);
}

static void append_carp_shortmess(pTHX_ SV *scalar)
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
	dTHX;
	va_list args;
	SV *scalar;

	va_start(args, format);
	scalar = sv_2mortal(vnewSVpvf(format, &args));
	va_end(args);

	append_carp_shortmess(aTHX_ scalar);

	if (!fatal)
		warn_sv(scalar);
	else
		croak_sv(scalar);
}

static bool string_contains_nul(const char *str, STRLEN len)
{
	return (memchr(str, 0, len + 1) != str + len);
}

static bool string_needs_utf8_upgrade(const char *str, STRLEN len)
{
	STRLEN i;

	for (i = 0; i < len; ++i)
		if (!UTF8_IS_INVARIANT(str[i]))
			return true;

	return false;
}

static const char *get_perl_scalar_value(pTHX_ SV *scalar, STRLEN *len, bool utf8, bool nomg)
{
	const char *string;

#ifndef WITHOUT_SvPV_nomg
	if (!nomg)
		SvGETMAGIC(scalar);

	if (!SvOK(scalar))
		return NULL;

	string = SvPV_nomg(scalar, *len);
#else
	COP cop;

	if (!SvGMAGICAL(scalar) && !SvOK(scalar))
		return NULL;

	/* Temporary turn off all warnings because SvPV can throw uninitialized warning */
	cop = *PL_curcop;
	cop.cop_warnings = pWARN_NONE;

	ENTER;
	SAVEVPTR(PL_curcop);
	PL_curcop = &cop;

	string = SvPV(scalar, *len);

	LEAVE;

	if (SvGMAGICAL(scalar) && !SvOK(scalar))
		return NULL;
#endif

	if (utf8 && !SvUTF8(scalar) && string_needs_utf8_upgrade(string, *len)) {
		scalar = sv_2mortal(newSVpvn(string, *len));
#ifdef BROKEN_SvPVutf8
		sv_utf8_upgrade(scalar);
		*len = SvCUR(scalar);
		return SvPVX(scalar);
#else
		return SvPVutf8(scalar, *len);
#endif
	}

	return string;
}

static const char *get_perl_scalar_string_value(pTHX_ SV *scalar, STRLEN *len, const char *name, bool utf8)
{
	const char *string;

	string = get_perl_scalar_value(aTHX_ scalar, len, utf8, false);
	if (!string) {
		carp(CARP_WARN, "Use of uninitialized value for %s", name);
		*len = 0;
		return "";
	}

	return string;
}

static SV *get_perl_hash_scalar(pTHX_ HV *hash, const char *key)
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

static const char *get_perl_hash_value(pTHX_ HV *hash, const char *key, STRLEN *len, bool utf8, bool *taint)
{
	SV *scalar;

	scalar = get_perl_hash_scalar(aTHX_ hash, key);
	if (!scalar)
		return NULL;

	if (!*taint && SvTAINTED(scalar))
		*taint = true;

	return get_perl_scalar_value(aTHX_ scalar, len, utf8, true);
}

static void set_perl_hash_value(pTHX_ HV *hash, const char *key, const char *value, bool utf8, bool taint)
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

	if (taint)
		SvTAINTED_on(scalar);

	(void)hv_store(hash, key, klen, scalar, 0);
}

static HV *get_perl_class_from_perl_cv(pTHX_ CV *cv)
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

static HV *get_perl_class_from_perl_scalar(pTHX_ SV *scalar)
{
	HV *class;
	STRLEN class_len;
	const char *class_name;

	class_name = get_perl_scalar_string_value(aTHX_ scalar, &class_len, "class", true);

	if (class_len == 0) {
		carp(CARP_WARN, "Explicit blessing to '' (assuming package main)");
		class_name = "main";
	}

	class = gv_stashpvn(class_name, class_len, GV_ADD | SVf_UTF8);
	if (!class)
		carp(CARP_DIE, "Cannot retrieve class %s", class_name);

	return class;
}

static HV *get_perl_class_from_perl_scalar_or_cv(pTHX_ SV *scalar, CV *cv)
{
	if (scalar)
		return get_perl_class_from_perl_scalar(aTHX_ scalar);
	else
		return get_perl_class_from_perl_cv(aTHX_ cv);
}

static bool is_class_object(pTHX_ SV *class, SV *object)
{
	dSP;
	SV *mortal_object;
	SV *mortal_class;
	SV *sv;
	bool ret;
	int count;

	if (!sv_isobject(object))
		return false;

	ENTER;
	SAVETMPS;

	PUSHMARK(SP);

	mortal_object = sv_newmortal();
	SvSetSV_nosteal(mortal_object, object);
	XPUSHs(mortal_object);

	mortal_class = sv_newmortal();
	SvSetSV_nosteal(mortal_class, class);
	XPUSHs(mortal_class);

	PUTBACK;

	count = call_method("isa", G_SCALAR);

	SPAGAIN;

	if (count > 0) {
		sv = POPs;
		ret = SvTRUE(sv);
	} else {
		ret = false;
	}

	PUTBACK;
	FREETMPS;
	LEAVE;

	return ret;
}

static HV* get_object_hash_from_perl_array(pTHX_ AV *array, I32 index1, I32 index2, SV *class, bool warn)
{
	SV *scalar;
	SV *object;
	SV **object_ptr;

#ifdef WITHOUT_SvPV_nomg
	warn = true;
#endif

	object_ptr = av_fetch(array, index2, 0);
	if (!object_ptr) {
		if (warn)
			carp(CARP_WARN, "Element at index %d/%d is NULL", (int)index1, (int)index2);
		return NULL;
	}

	object = *object_ptr;
	if (!is_class_object(aTHX_ class, object)) {
		if (warn)
			carp(CARP_WARN, "Element at index %d/%d is not %s object", (int)index1, (int)index2, SvPV_nolen(class));
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

static void message_address_add_from_perl_array(pTHX_ struct message_address **first_address, struct message_address **last_address, bool utf8, bool *taint, AV *array, I32 index1, I32 index2, SV *class)
{
	HV *hash;
	const char *name;
	const char *mailbox;
	const char *domain;
	const char *comment;
	STRLEN name_len;
	STRLEN mailbox_len;
	STRLEN domain_len;
	STRLEN comment_len;

	hash = get_object_hash_from_perl_array(aTHX_ array, index1, index2, class, false);
	if (!hash)
		return;

	name = get_perl_hash_value(aTHX_ hash, "phrase", &name_len, utf8, taint);
	mailbox = get_perl_hash_value(aTHX_ hash, "user", &mailbox_len, utf8, taint);
	domain = get_perl_hash_value(aTHX_ hash, "host", &domain_len, utf8, taint);
	comment = get_perl_hash_value(aTHX_ hash, "comment", &comment_len, utf8, taint);

	if (name && string_contains_nul(name, name_len))
		carp(CARP_WARN, "Element at index %d/%d contains nul character in phrase", (int)index1, (int)index2);

	if (mailbox && string_contains_nul(mailbox, mailbox_len))
		carp(CARP_WARN, "Element at index %d/%d contains nul character in user portion of address", (int)index1, (int)index2);

	if (domain && string_contains_nul(domain, domain_len))
		carp(CARP_WARN, "Element at index %d/%d contains nul character in host portion of address", (int)index1, (int)index2);

	if (comment && string_contains_nul(comment, comment_len))
		carp(CARP_WARN, "Element at index %d/%d contains nul character in comment", (int)index1, (int)index2);

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

#ifdef WITHOUT_SvPV_nomg
	warn = true;
#endif

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

static void message_address_add_from_perl_group(pTHX_ struct message_address **first_address, struct message_address **last_address, bool utf8, bool *taint, SV *scalar_group, SV *scalar_list, I32 index1, SV *class)
{
	I32 len;
	I32 index2;
	AV *array;
	STRLEN group_len;
	const char *group_name;

	group_name = get_perl_scalar_value(aTHX_ scalar_group, &group_len, utf8, true);
	array = get_perl_array_from_scalar(scalar_list, group_name, false);
	len = array ? (av_len(array) + 1) : 0;

	if (group_name && string_contains_nul(group_name, group_len))
		carp(CARP_WARN, "Group name '%s' contains nul character", group_name);

	if (group_name)
		message_address_add(first_address, last_address, NULL, NULL, group_name, NULL, NULL);

	for (index2 = 0; index2 < len; ++index2)
		message_address_add_from_perl_array(aTHX_ first_address, last_address, utf8, taint, array, index1, index2, class);

	if (group_name)
		message_address_add(first_address, last_address, NULL, NULL, NULL, NULL, NULL);

	if (!*taint && SvTAINTED(scalar_group))
		*taint = true;
}

#ifndef WITHOUT_SvPV_nomg
static bool perl_group_needs_utf8(pTHX_ SV *scalar_group, SV *scalar_list, I32 index1, SV *class)
{
	I32 len;
	I32 index2;
	SV *scalar;
	HV *hash;
	AV *array;
	STRLEN len_na;
	bool utf8;
	const char *group_name;
	const char **hash_key_ptr;

	static const char *hash_keys[] = { "phrase", "user", "host", "comment", NULL };

	utf8 = false;

	group_name = get_perl_scalar_value(aTHX_ scalar_group, &len_na, false, false);
	if (SvUTF8(scalar_group))
		utf8 = true;

	array = get_perl_array_from_scalar(scalar_list, group_name, true);
	len = array ? (av_len(array) + 1) : 0;

	for (index2 = 0; index2 < len; ++index2) {
		hash = get_object_hash_from_perl_array(aTHX_ array, index1, index2, class, true);
		if (!hash)
			continue;
		for (hash_key_ptr = hash_keys; *hash_key_ptr; ++hash_key_ptr) {
			scalar = get_perl_hash_scalar(aTHX_ hash, *hash_key_ptr);
			if (scalar && get_perl_scalar_value(aTHX_ scalar, &len_na, false, false) && SvUTF8(scalar))
				utf8 = true;
		}
	}

	return utf8;
}
#endif

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

static bool get_next_perl_address_group(pTHX_ struct message_address **address, SV **group_scalar, SV **addresses_scalar, HV *class, bool utf8, bool taint)
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

	if (taint)
		SvTAINTED_on(*group_scalar);

	addresses_array = newAV();
	*addresses_scalar = newRV_noinc((SV *)addresses_array);

	if (in_group)
		*address = (*address)->next;

	while (*address && (*address)->domain) {
		hash = newHV();

		set_perl_hash_value(aTHX_ hash, "phrase", (*address)->name, utf8, taint);
		set_perl_hash_value(aTHX_ hash, "user", ( (*address)->mailbox && (*address)->mailbox[0] ) ? (*address)->mailbox : NULL, utf8, taint);
		set_perl_hash_value(aTHX_ hash, "host", ( (*address)->domain && (*address)->domain[0] ) ? (*address)->domain : NULL, utf8, taint);
		set_perl_hash_value(aTHX_ hash, "comment", (*address)->comment, utf8, taint);

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
	bool taint;
	char *string;
	struct message_address *first_address;
	struct message_address *last_address;
INPUT:
	SV *this_class = sv_2mortal(newSVpvn_utf8("$Package", sizeof("$Package")-1, 1));
INIT:
	if (items % 2 == 1) {
		carp(CARP_WARN, "Odd number of elements in argument list");
		XSRETURN_UNDEF;
	}
CODE:
	first_address = NULL;
	last_address = NULL;
	taint = false;
#ifndef WITHOUT_SvPV_nomg
	utf8 = false;
	for (i = 0; i < items; i += 2)
		if (perl_group_needs_utf8(aTHX_ ST(i), ST(i+1), i, this_class))
			utf8 = true;
#else
	utf8 = true;
#endif
	for (i = 0; i < items; i += 2)
		message_address_add_from_perl_group(aTHX_ &first_address, &last_address, utf8, &taint, ST(i), ST(i+1), i, this_class);
	message_address_write(&string, first_address);
	message_address_free(&first_address);
	RETVAL = newSVpv(string, 0);
	if (utf8)
		sv_utf8_decode(RETVAL);
	if (taint)
		SvTAINTED_on(RETVAL);
	string_free(string);
OUTPUT:
	RETVAL

void
parse_email_groups(...)
PREINIT:
	SV *string_scalar;
	SV *class_scalar;
	int count;
	HV *hv_class;
	SV *group_scalar;
	SV *addresses_scalar;
	bool utf8;
	bool taint;
	STRLEN input_len;
	const char *input;
	const char *class_name;
	struct message_address *address;
	struct message_address *first_address;
INPUT:
	const char *this_class_name = "$Package";
	STRLEN this_class_len = sizeof("$Package")-1;
INIT:
	string_scalar = items >= 1 ? ST(0) : &PL_sv_undef;
	class_scalar = items >= 2 ? ST(1) : NULL;
	input = get_perl_scalar_string_value(aTHX_ string_scalar, &input_len, "string", false);
	utf8 = SvUTF8(string_scalar);
	taint = SvTAINTED(string_scalar);
	hv_class = get_perl_class_from_perl_scalar_or_cv(aTHX_ class_scalar, cv);
	if (class_scalar && !sv_derived_from_pvn(class_scalar, this_class_name, this_class_len, SVf_UTF8)) {
		class_name = HvNAME(hv_class);
		carp(CARP_WARN, "Class %s is not derived from %s", (class_name ? class_name : "(unknown)"), this_class_name);
		XSRETURN_EMPTY;
	}
PPCODE:
	first_address = message_address_parse(input, input_len, UINT_MAX, false);
	count = count_address_groups(first_address);
	EXTEND(SP, count * 2);
	address = first_address;
	while (get_next_perl_address_group(aTHX_ &address, &group_scalar, &addresses_scalar, hv_class, utf8, taint)) {
		PUSHs(sv_2mortal(group_scalar));
		PUSHs(sv_2mortal(addresses_scalar));
	}
	message_address_free(&first_address);

SV *
compose_address(...)
PREINIT:
	char *string;
	const char *mailbox;
	const char *domain;
	STRLEN mailbox_len;
	STRLEN domain_len;
	bool utf8;
	bool taint;
	SV *mailbox_scalar;
	SV *domain_scalar;
INIT:
	mailbox_scalar = items >= 1 ? ST(0) : &PL_sv_undef;
	domain_scalar = items >= 2 ? ST(1) : &PL_sv_undef;
	mailbox = get_perl_scalar_string_value(aTHX_ mailbox_scalar, &mailbox_len, "mailbox", true);
	domain = get_perl_scalar_string_value(aTHX_ domain_scalar, &domain_len, "domain", true);
	utf8 = (SvUTF8(mailbox_scalar) || SvUTF8(domain_scalar));
	taint = (SvTAINTED(mailbox_scalar) || SvTAINTED(domain_scalar));
	if (string_contains_nul(mailbox, mailbox_len))
		carp(CARP_WARN, "Nul character in user portion of address");
	if (string_contains_nul(domain, domain_len))
		carp(CARP_WARN, "Nul character in host portion of address");
CODE:
	compose_address(&string, mailbox, domain);
	RETVAL = newSVpv(string, 0);
	if (utf8)
		sv_utf8_decode(RETVAL);
	if (taint)
		SvTAINTED_on(RETVAL);
	string_free(string);
OUTPUT:
	RETVAL

void
split_address(...)
PREINIT:
	const char *string;
	char *mailbox;
	char *domain;
	STRLEN string_len;
	bool utf8;
	bool taint;
	SV *string_scalar;
	SV *mailbox_scalar;
	SV *domain_scalar;
INIT:
	string_scalar = items >= 1 ? ST(0) : &PL_sv_undef;
	string = get_perl_scalar_string_value(aTHX_ string_scalar, &string_len, "string", false);
	utf8 = SvUTF8(string_scalar);
	taint = SvTAINTED(string_scalar);
PPCODE:
	split_address(string, string_len, &mailbox, &domain);
	mailbox_scalar = mailbox ? newSVpv(mailbox, 0) : newSV(0);
	domain_scalar = domain ? newSVpv(domain, 0) : newSV(0);
	string_free(mailbox);
	string_free(domain);
	if (utf8) {
		sv_utf8_decode(mailbox_scalar);
		sv_utf8_decode(domain_scalar);
	}
	if (taint) {
		SvTAINTED_on(mailbox_scalar);
		SvTAINTED_on(domain_scalar);
	}
	EXTEND(SP, 2);
	PUSHs(sv_2mortal(mailbox_scalar));
	PUSHs(sv_2mortal(domain_scalar));

bool
is_obj(...)
PREINIT:
	SV *class = items >= 1 ? ST(0) : &PL_sv_undef;
	SV *object = items >= 2 ? ST(1) : &PL_sv_undef;
CODE:
	RETVAL = is_class_object(aTHX_ class, object);
OUTPUT:
	RETVAL
