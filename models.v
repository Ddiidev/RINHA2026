module main

struct Transaction {
	amount       f64
	installments int
	requested_at string
}

struct Customer {
	avg_amount      f64
	tx_count_24h    int
	known_merchants []string
}

struct Merchant {
	id         string
	mcc        string
	avg_amount f64
}

struct Terminal {
	is_online    bool
	card_present bool
	km_from_home f64
}

struct LastTransaction {
	timestamp       string
	km_from_current f64
}

struct FraudRequest {
	id               string
	transaction      Transaction
	customer         Customer
	merchant         Merchant
	terminal         Terminal
	last_transaction ?LastTransaction
}

struct FraudResponse {
	approved    bool
	fraud_score f64
}

fn default_response() FraudResponse {
	return FraudResponse{
		approved:    true
		fraud_score: 0.0
	}
}
