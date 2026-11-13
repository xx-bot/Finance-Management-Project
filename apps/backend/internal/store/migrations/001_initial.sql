CREATE TABLE users (
    id UUID PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    password_hash BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
    token_hash BYTEA PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX sessions_expiration ON sessions(expires_at);

CREATE TABLE expenses (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    merchant TEXT NOT NULL,
    receipt_date DATE NOT NULL,
    currency TEXT NOT NULL CHECK (currency IN ('IDR', 'MYR', 'USD')),
    total_minor BIGINT NOT NULL CHECK (total_minor BETWEEN 0 AND 9007199254740991),
    category TEXT NOT NULL,
    adjustments JSONB NOT NULL DEFAULT '[]',
    note TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('verified', 'reviewed_difference')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, id)
);
CREATE INDEX expenses_by_month ON expenses(user_id, currency, receipt_date DESC, id DESC);

CREATE TABLE expense_items (
    user_id UUID NOT NULL,
    expense_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    description TEXT NOT NULL,
    amount_minor BIGINT NOT NULL CHECK (amount_minor BETWEEN 0 AND 9007199254740991),
    category TEXT NOT NULL,
    quantity TEXT,
    unit_price TEXT,
    sub_items JSONB NOT NULL DEFAULT '[]',
    PRIMARY KEY (user_id, expense_id, position),
    FOREIGN KEY (user_id, expense_id) REFERENCES expenses(user_id, id) ON DELETE CASCADE
);

CREATE TABLE budgets (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    currency TEXT NOT NULL CHECK (currency IN ('IDR', 'MYR', 'USD')),
    amount_minor BIGINT NOT NULL CHECK (amount_minor BETWEEN 1 AND 9007199254740991),
    PRIMARY KEY (user_id, currency)
);
