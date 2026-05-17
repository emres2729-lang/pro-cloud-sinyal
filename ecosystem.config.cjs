module.exports = {
  apps: [
    {
      name: 'sinyal-motor',
      script: 'scripts/sinyal.mjs',
      interpreter: 'node',
      cwd: process.cwd(),
      restart_delay: 5000,
      max_restarts: 100,
      min_uptime: '10s',
      out_file:  'logs/sinyal_out.log',
      error_file: 'logs/sinyal_err.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      merge_logs: true,
    },
    {
      name: 'webhook-server',
      script: 'scripts/webhook_server.mjs',
      interpreter: 'node',
      cwd: process.cwd(),
      restart_delay: 3000,
      max_restarts: 100,
      min_uptime: '5s',
      out_file:  'logs/webhook_out.log',
      error_file: 'logs/webhook_err.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      merge_logs: true,
    },
  ]
};
