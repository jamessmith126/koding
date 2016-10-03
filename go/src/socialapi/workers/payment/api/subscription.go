package api

import (
	"net/http"
	"net/url"
	"socialapi/models"
	"socialapi/workers/common/response"
	"socialapi/workers/payment"

	"github.com/stripe/stripe-go"
)

// CancelSubscription cancels the subscription of group
func CancelSubscription(u *url.URL, h http.Header, _ interface{}, context *models.Context) (int, http.Header, interface{}, error) {
	if err := checkContext(context); err != nil {
		return response.NewBadRequest(err)
	}

	return response.HandleResultAndError(
		payment.CancelSubscriptionForGroup(context.GroupName),
	)
}

// GetSubscription gets the subscription of group
func GetSubscription(u *url.URL, h http.Header, _ interface{}, context *models.Context) (int, http.Header, interface{}, error) {
	if !context.IsLoggedIn() {
		return response.NewBadRequest(models.ErrNotLoggedIn)
	}

	return response.HandleResultAndError(
		payment.GetSubscriptionForGroup(context.GroupName),
	)
}

// CreateSubscription creates the subscription of group
func CreateSubscription(u *url.URL, h http.Header, params *stripe.SubParams, context *models.Context) (int, http.Header, interface{}, error) {
	if err := checkContext(context); err != nil {
		return response.NewBadRequest(err)
	}

	// TODO
	// Add idempotency here
	//

	return response.HandleResultAndError(
		payment.CreateSubscriptionForGroup(context.GroupName, params),
	)
}
