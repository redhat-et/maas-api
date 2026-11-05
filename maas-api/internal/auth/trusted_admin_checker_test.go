package auth_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/opendatahub-io/models-as-a-service/maas-api/internal/auth"
	"github.com/opendatahub-io/models-as-a-service/maas-api/internal/token"
)

func TestTrustedAdminChecker(t *testing.T) {
	checker := auth.NewTrustedAdminChecker("admin", " oncall ")

	t.Run("configured user is admin", func(t *testing.T) {
		ok, err := checker.IsAdmin(context.Background(), &token.UserContext{Username: "admin"})
		require.NoError(t, err)
		assert.True(t, ok)
	})

	t.Run("trimmed configured user is admin", func(t *testing.T) {
		ok, err := checker.IsAdmin(context.Background(), &token.UserContext{Username: "oncall"})
		require.NoError(t, err)
		assert.True(t, ok)
	})

	t.Run("regular user is not admin", func(t *testing.T) {
		ok, err := checker.IsAdmin(context.Background(), &token.UserContext{Username: "alice"})
		require.NoError(t, err)
		assert.False(t, ok)
	})

	t.Run("nil user is not admin", func(t *testing.T) {
		ok, err := checker.IsAdmin(context.Background(), nil)
		require.NoError(t, err)
		assert.False(t, ok)
	})
}
