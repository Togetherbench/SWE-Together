Bug: [FEATURE] L2-l3 data for checkout



### Feature Description

Add l2-l3 data for checkout

### Possible Implementation

https://www.checkout.com/docs/payments/manage-payments/submit-level-2-or-level-3-data

### Have you spent some time checking if this feature request has been raised before?

- [x] I checked and didn't find a similar issue

### Have you read the Contributing Guidelines?

- [x] I have read the [Contributing Guidelines](https://github.com/juspay/hyperswitch/blob/main/docs/CONTRIBUTING.md)

### Are you willing to submit a PR?

None

DETAILED CONTEXT & HINTS:
## Type of Change
<!-- Put an `x` in the boxes that apply -->

- [ ] Bugfix
- [x] New feature
- [ ] Enhancement
- [ ] Refactoring
- [ ] Dependency updates
- [ ] Documentation
- [ ] CI/CD

## Description
- Add l2l3 data for checkout
- Note : checkout recommends some checks like line_items should sum up proper total and discount amount. But it doesn't throw any errors for this. Hence in this pr we are not adding any such validations .

## Request

```json
{
    "amount": 30000,
    "capture_method": "automatic",
    "currency": "USD",
    "confirm": true,
    "payment_method": "card",
    "payment_method_type": "credit",
    "billing": {
        "address": {
            "zip": "560095",
            "country": "AT",
            "first_name": "Sakil",
            "last_name": "Mostak",
            "line1": "Fasdf",
            "line2": "Fasdf",
            "city": "Fasdf"
        }
    },
    "payment_method_data": {
        "card": {
            "card_number": "4000000000009995",
            "card_exp_month": "01",
            "card_exp_year": "2026",
            "card_holder_name": "John Smith",
            "card_cvc": "100"
        }
    },

    //l2l3 data
    "merchant_order_reference_id":"fasdfasfasf",
    "customer_id": "nithxxinn",
    "order_tax_amount": 10000,
    "shipping_cost": 21,
    "discount_amount": 1,
    "duty_amount": 2,
    "shipping_amount_tax":22,
    "order_details": [ //l2 l3data
        {
            "commodity_code": "8471",
            "unit_discount_amount": 1200,
            "product_name": "Laptop",
            "quantity": 1,
            "product_id":"fafasdfasdfdasdfsadfsadfrewfdscrwefdscerwfdasewfdsacxzfdsasdf",
            "total_tax_amount": 5000,
            "amount": 8000,
            "unit_of_measure": "EA",
            "unit_price": 8000
        },
            {
            "commodity_code": "471",
            "unit_discount_amount": 34,
            "product_name": "Laptop",
            "quantity": 1,
            "product_id":"fas22df",
            "total_tax_amount": 3000,
            "amount": 4000,
            "unit_of_measure": "EA",
            "unit_price": 8500
        }
        
    ]
}
```

## Response

```json
{
    "payment_id": "pay_v01RncbYqwx0ZtB6x7yV",
    "merchant_id": "merchant_1758258316",
    "status": "succeeded",
    "amount": 30000,
    "net_amount": 40021,
    "shipping_cost": 21,
    "amount_capturable": 0,
    "amount_received": 40021,
    "connector": "checkout",
    "client_secret": "pay_v01RncbYqwx0ZtB6x7yV_secret_iolJ5SxVFNsQljPaO42C",
    "created": "2025-09-19T06:18:02.547Z",
    "currency": "USD",
    "customer_id": "nithxxinn",
    "customer": {
        "id": "nithxxinn",
        "name": null,
        "email": null,
        "phone": null,
        "phone_country_code": null
    },
    "description": null,
    "refunds": null,
    "disputes": null,
    "mandate_id": null,
    "mandate_data": null,
    "setup_future_usage": null,
    "off_session": null,
    "capture_on": null,
    "capture_method": "automatic",
    "payment_method": "card",
    "payment_method_data": {
        "card": {
            "last4": "9995",
            "card_type": null,
            "card_network": null,
            "card_issuer": null,
            "card_issuing_country": null,
            "card_isin": "400000",
            "card_extended_bin": null,
            "card_exp_month": "01",
            "card_exp_year": "2026",
            "card_holder_name": "John Smith",
            "payment_checks": {
                "avs_result": "G",
                "card_validation_result": "Y"
            },
            "authentication_data": null
        },
        "billing": null
    },
    "payment_token": null,
    "shipping": null,
    "billing": {
        "address": {
            "city": "Fasdf",
            "country": "AT",
            "line1": "Fasdf",
            "line2": "Fasdf",
            "line3": null,
            "zip": "560095",
            "state": null,
            "first_name": "Sakil",
            "last_name": "Mostak",
            "origin_zip": null
        },
        "phone": null,
        "email": null
    },
    "order_details": [
        {
            "sku": null,
            "upc": null,
            "brand": null,
            "amount": 8000,
            "category": null,
            "quantity": 1,
            "tax_rate": null,
            "product_id": "fafasdfasdfdasdfsadfsadfrewfds
