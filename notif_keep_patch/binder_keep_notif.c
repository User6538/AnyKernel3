/*
 * notif_keep_patch/binder_keep_notif.c — keep notification on force-stop
 *
 * This file is injected into drivers/android/binder.c by inject_binder_notif.py.
 * It defines a helper that scans a binder transaction buffer for the
 * "android.intent.action.PACKAGE_RESTARTED" action string (both UTF-8 and
 * UTF-16LE encodings) and zeroes the matched character data in place.
 *
 * Why this works:
 *  - Android's forceStopPackage() sends ACTION_PACKAGE_RESTARTED broadcast;
 *    NotificationManagerService receives it and clears the app's notifications.
 *  - The broadcast is delivered as a normal binder transaction whose buffer
 *    data contains the Intent's serialized action string.
 *  - We only blank the action *character data* (not the Parcel length field
 *    nor the terminator), so Parcel structure stays intact and
 *    Intent.getAction() returns "" -> NMS no longer matches -> notifications kept.
 *
 * No sysctl node is created: the behavior is compile-time only, leaving no
 * runtime detection surface (no /proc/sys/kernel/keep_notif, no module entry).
 *
 * User6538/AnyKernel3 — keep notification on force-stop
 */

/* UTF-16LE encoding of the action string (Parcel stores Java String as UTF-16). */
static const u8 binder_keep_notif_utf16[] = {
	'a', 0, 'n', 0, 'd', 0, 'r', 0, 'o', 0, 'i', 0, 'd', 0, '.', 0,
	'i', 0, 'n', 0, 't', 0, 'e', 0, 'n', 0, 't', 0, '.', 0,
	'a', 0, 'c', 0, 't', 0, 'i', 0, 'o', 0, 'n', 0, '.', 0,
	'P', 0, 'A', 0, 'C', 0, 'K', 0, 'A', 0, 'G', 0, 'E', 0,
	'_', 0, 'R', 0, 'E', 0, 'S', 0, 'T', 0, 'A', 0, 'R', 0,
	'T', 0, 'E', 0, 'D', 0
};

/* UTF-8 form: some Intent serialization paths store the action as UTF-8. */
static const char binder_keep_notif_utf8[] =
	"android.intent.action.PACKAGE_RESTARTED";

/*
 * binder_keep_notif_filter - blank PACKAGE_RESTARTED action in a transaction
 * @t: the binder transaction being delivered (t->buffer->data already filled)
 *
 * Called from binder_proc_transaction() right before the transaction is queued
 * to the target process. At this point t->buffer->data holds the fully copied
 * Parcel payload, so we can scan it safely without extra locking.
 *
 * We only touch the action character bytes; the surrounding Parcel length /
 * type / terminator fields are preserved, so the receiver deserializes a
 * well-formed Intent whose getAction() returns the empty string.
 */
static void binder_keep_notif_filter(struct binder_transaction *t)
{
	struct binder_buffer *buf;
	size_t i, data_size;
	u8 *data;

	if (!t)
		return;
	buf = t->buffer;
	if (!buf)
		return;
	data = buf->data;
	data_size = buf->data_size;
	if (!data || data_size < sizeof(binder_keep_notif_utf16))
		return;

	/* Primary: UTF-16LE (Java Parcel String layout). */
	for (i = 0; i + sizeof(binder_keep_notif_utf16) <= data_size; i++) {
		if (memcmp(data + i, binder_keep_notif_utf16,
			   sizeof(binder_keep_notif_utf16)) == 0) {
			memset(data + i, 0, sizeof(binder_keep_notif_utf16));
			return;
		}
	}

	/* Fallback: UTF-8 form (some flatten paths). */
	for (i = 0;
	     i + sizeof(binder_keep_notif_utf8) - 1 <= data_size; i++) {
		if (memcmp(data + i, binder_keep_notif_utf8,
			   sizeof(binder_keep_notif_utf8) - 1) == 0) {
			memset(data + i, 0, sizeof(binder_keep_notif_utf8) - 1);
			return;
		}
	}
}
