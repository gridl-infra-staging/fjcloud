use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum BillingHealth {
    Red,
    Yellow,
    Grey,
    Green,
}

/// Derive tenant billing health from customer status + subscription state.
pub fn derive(
    customer_status: &str,
    subscription_status: Option<&str>,
    overdue_invoice_count: i64,
) -> BillingHealth {
    if customer_status == "deleted" {
        return BillingHealth::Grey;
    }

    let Some(subscription_status) = subscription_status else {
        return BillingHealth::Grey;
    };

    match subscription_status {
        "past_due" | "unpaid" => BillingHealth::Red,
        "incomplete" => BillingHealth::Yellow,
        _ if overdue_invoice_count > 0 => BillingHealth::Yellow,
        "active" | "trialing" => BillingHealth::Green,
        _ => BillingHealth::Grey,
    }
}

#[cfg(test)]
mod tests {
    use super::{derive, BillingHealth};

    #[test]
    fn deleted_status_overrides_other_inputs_to_grey() {
        let observed = derive("deleted", Some("past_due"), 4);
        assert_eq!(observed, BillingHealth::Grey);
    }

    #[test]
    fn missing_subscription_status_is_grey_even_with_overdue_invoices() {
        let observed = derive("active", None, 3);
        assert_eq!(observed, BillingHealth::Grey);
    }

    #[test]
    fn past_due_and_unpaid_are_red() {
        assert_eq!(derive("active", Some("past_due"), 0), BillingHealth::Red);
        assert_eq!(derive("active", Some("unpaid"), 0), BillingHealth::Red);
    }

    #[test]
    fn incomplete_or_positive_overdue_is_yellow() {
        assert_eq!(
            derive("active", Some("incomplete"), 0),
            BillingHealth::Yellow
        );
        assert_eq!(derive("active", Some("active"), 2), BillingHealth::Yellow);
    }

    #[test]
    fn active_or_trialing_with_zero_overdue_is_green() {
        assert_eq!(derive("active", Some("active"), 0), BillingHealth::Green);
        assert_eq!(derive("active", Some("trialing"), 0), BillingHealth::Green);
    }

    #[test]
    fn unknown_subscription_status_falls_back_to_grey() {
        assert_eq!(
            derive("active", Some("something_new"), 0),
            BillingHealth::Grey
        );
    }
}
