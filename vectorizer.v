module main

import time

const vector_dims = 14
const quant_scale = 32767.0
const missing_quant = i16(-32768)

fn vectorize(payload FraudRequest) ![]i16 {
	requested := parse_utc(payload.transaction.requested_at)!
	mut v := []i16{len: vector_dims}
	v[0] = quantize_normal(clamp01(payload.transaction.amount / 10000.0))
	v[1] = quantize_normal(clamp01(f64(payload.transaction.installments) / 12.0))
	v[2] = quantize_normal(clamp01(amount_vs_avg(payload.transaction.amount,
		payload.customer.avg_amount)))
	v[3] = quantize_normal(f64(requested.hour) / 23.0)
	v[4] = quantize_normal(f64(requested.official_weekday) / 6.0)
	if last := payload.last_transaction {
		previous := parse_utc(last.timestamp)!
		minutes := f64(requested.unix_seconds - previous.unix_seconds) / 60.0
		v[5] = quantize_normal(clamp01(minutes / 1440.0))
		v[6] = quantize_normal(clamp01(last.km_from_current / 1000.0))
	} else {
		v[5] = missing_quant
		v[6] = missing_quant
	}
	v[7] = quantize_normal(clamp01(payload.terminal.km_from_home / 1000.0))
	v[8] = quantize_normal(clamp01(f64(payload.customer.tx_count_24h) / 20.0))
	v[9] = if payload.terminal.is_online { quantize_normal(1.0) } else { quantize_normal(0.0) }
	v[10] = if payload.terminal.card_present { quantize_normal(1.0) } else { quantize_normal(0.0) }
	v[11] = if merchant_is_known(payload.merchant.id, payload.customer.known_merchants) {
		quantize_normal(0.0)
	} else {
		quantize_normal(1.0)
	}
	v[12] = quantize_normal(mcc_risk(payload.merchant.mcc))
	v[13] = quantize_normal(clamp01(payload.merchant.avg_amount / 10000.0))
	return v
}

fn amount_vs_avg(amount f64, avg_amount f64) f64 {
	if avg_amount <= 0 {
		return if amount > 0 { 1.0 } else { 0.0 }
	}
	return (amount / avg_amount) / 10.0
}

fn clamp01(x f64) f64 {
	if x < 0 {
		return 0.0
	}
	if x > 1 {
		return 1.0
	}
	return x
}

fn quantize_value(x f64) i16 {
	if x < -0.5 {
		return missing_quant
	}
	return quantize_normal(clamp01(x))
}

fn quantize_normal(x f64) i16 {
	return i16(int(x * quant_scale + 0.5))
}

fn merchant_is_known(id string, known []string) bool {
	for merchant in known {
		if merchant == id {
			return true
		}
	}
	return false
}

fn mcc_risk(mcc string) f64 {
	return match mcc {
		'5411' { 0.15 }
		'5812' { 0.30 }
		'5912' { 0.20 }
		'5944' { 0.45 }
		'7801' { 0.80 }
		'7802' { 0.75 }
		'7995' { 0.85 }
		'4511' { 0.35 }
		'5311' { 0.25 }
		'5999' { 0.50 }
		else { 0.50 }
	}
}

struct ParsedUtc {
	hour             int
	official_weekday int
	unix_seconds     i64
}

fn parse_utc(s string) !ParsedUtc {
	if s.len < 20 {
		return error('invalid timestamp')
	}
	year := digits4(s, 0)
	month := digits2(s, 5)
	day := digits2(s, 8)
	hour := digits2(s, 11)
	minute := digits2(s, 14)
	second := digits2(s, 17)
	days := time.days_from_unix_epoch(year, month, day)
	weekday_v := time.day_of_week(year, month, day)
	return ParsedUtc{
		hour:             hour
		official_weekday: (weekday_v + 6) % 7
		unix_seconds:     i64(days) * 86400 + i64(hour * 3600 + minute * 60 + second)
	}
}

fn digit_at(s string, idx int) int {
	return int(s[idx] - `0`)
}

fn digits2(s string, idx int) int {
	return digit_at(s, idx) * 10 + digit_at(s, idx + 1)
}

fn digits4(s string, idx int) int {
	return digit_at(s, idx) * 1000 + digit_at(s, idx + 1) * 100 + digit_at(s, idx + 2) * 10 +
		digit_at(s, idx + 3)
}
