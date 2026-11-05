package auth

import (
	"context"
	"strings"

	"github.com/opendatahub-io/models-as-a-service/maas-api/internal/token"
)

// TrustedAdminChecker treats configured usernames as administrators for the
// EnMaaS standalone profile. It performs no Kubernetes SubjectAccessReview.
type TrustedAdminChecker struct {
	admins map[string]struct{}
}

// NewTrustedAdminChecker builds an admin checker from trusted usernames.
func NewTrustedAdminChecker(admins ...string) *TrustedAdminChecker {
	checker := &TrustedAdminChecker{admins: make(map[string]struct{}, len(admins))}
	for _, admin := range admins {
		if name := strings.TrimSpace(admin); name != "" {
			checker.admins[name] = struct{}{}
		}
	}
	return checker
}

// IsAdmin reports whether the authenticated user is in the trusted admin list.
func (c *TrustedAdminChecker) IsAdmin(_ context.Context, user *token.UserContext) (bool, error) {
	if c == nil || user == nil {
		return false, nil
	}
	_, ok := c.admins[strings.TrimSpace(user.Username)]
	return ok, nil
}
