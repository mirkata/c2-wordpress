<?php
/**
 * Plugin Name: Fix AI Engine Constant Conflict
 * Description: Prevents constant redefinition warnings between ai-engine plugins
 * Version: 1.0.0
 */

require_once ABSPATH . 'wp-admin/includes/plugin.php';

$free_plugin = 'ai-engine/ai-engine.php';
$pro_plugin = 'ai-engine-pro/ai-engine-pro.php';

if ( is_plugin_active( $pro_plugin ) && is_plugin_active( $free_plugin ) ) {
    deactivate_plugins( $free_plugin );
}