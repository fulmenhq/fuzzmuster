package config

// Config is the operator configuration read from
// ~/.config/<vendor>/<config_name>.yaml. No settings are defined yet; a file
// that sets any key is refused, so a setting is never silently ignored.
type Config struct{}
