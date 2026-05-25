import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useSession } from '../hooks/useSession'

// ── ECS Provisioning Overlay ─────────────────────────────────────
const PROVISION_STEPS = [
  'Allocating compute',
  'Configuring Linux environment',
  'Starting shell server',
  'Connecting to workspace',
]

function ProvisioningOverlay({ step }: { step: number }) {
  return (
    <div style={{
      position: 'fixed', inset: 0, zIndex: 100,
      background: 'rgba(6,10,15,0.97)', backdropFilter: 'blur(16px)',
      display: 'flex', flexDirection: 'column',
      alignItems: 'center', justifyContent: 'center', gap: 32,
    }}>
      {/* Spinner ring */}
      <div style={{ position: 'relative', width: 72, height: 72 }}>
        <div style={{
          position: 'absolute', inset: 0, borderRadius: '50%',
          border: '3px solid rgba(88,166,255,0.15)',
          borderTopColor: '#58a6ff',
          animation: 'spin 0.9s linear infinite',
        }} />
        <div style={{
          position: 'absolute', inset: 12, borderRadius: '50%',
          border: '2px solid rgba(188,140,255,0.15)',
          borderTopColor: '#bc8cff',
          animation: 'spin 1.4s linear infinite reverse',
        }} />
      </div>

      <div style={{ textAlign: 'center' }}>
        <div style={{ fontSize: 20, fontWeight: 700, color: '#e6edf3', marginBottom: 8, letterSpacing: '-0.02em' }}>
          Launching your environment
        </div>
        <div style={{ fontSize: 13, color: '#484f58' }}>
          Spinning up an isolated ECS container for you
        </div>
      </div>

      {/* Steps */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 280 }}>
        {PROVISION_STEPS.map((label, i) => {
          const done    = i < step
          const active  = i === step
          const pending = i > step
          return (
            <div key={i} style={{
              display: 'flex', alignItems: 'center', gap: 12,
              opacity: pending ? 0.3 : 1,
              transition: 'opacity 0.4s',
            }}>
              <div style={{
                width: 22, height: 22, borderRadius: '50%', flexShrink: 0,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 11, fontWeight: 700,
                background: done
                  ? 'rgba(63,185,80,0.15)'
                  : active
                    ? 'rgba(88,166,255,0.12)'
                    : 'rgba(48,54,61,0.4)',
                border: `1.5px solid ${done ? '#3fb950' : active ? '#58a6ff' : 'rgba(48,54,61,0.6)'}`,
                color: done ? '#3fb950' : '#58a6ff',
              }}>
                {done ? '✓' : active ? (
                  <div style={{
                    width: 7, height: 7, borderRadius: '50%',
                    background: '#58a6ff',
                    animation: 'pulse 1s ease-in-out infinite',
                  }} />
                ) : null}
              </div>
              <span style={{
                fontSize: 14, color: done ? '#3fb950' : active ? '#e6edf3' : '#8b949e',
                fontWeight: active ? 600 : 400,
                transition: 'color 0.4s',
              }}>
                {label}
              </span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

// ── Waiting Room Overlay ──────────────────────────────────────────
function WaitingState({ active, total, waitSeconds, onRetry, isRetrying }: {
  active: number; total: number; waitSeconds: number
  onRetry: () => void; isRetrying: boolean
}) {
  const [countdown, setCountdown] = useState(waitSeconds)
  useEffect(() => {
    if (countdown <= 0) { onRetry(); return }
    const t = setInterval(() => setCountdown(c => c - 1), 1000)
    return () => clearInterval(t)
  }, [countdown <= 0])

  const pct  = Math.round((active / total) * 100)
  const mins = Math.ceil(countdown / 60)

  return (
    <div style={{
      position: 'fixed', inset: 0, zIndex: 100,
      background: 'rgba(6,10,15,0.96)', backdropFilter: 'blur(16px)',
      display: 'flex', flexDirection: 'column',
      alignItems: 'center', justifyContent: 'center', gap: 24,
    }}>
      <div style={{ fontSize: 42, lineHeight: 1 }}>⏳</div>
      <div style={{ fontSize: 22, fontWeight: 700, color: '#e6edf3' }}>All slots are full</div>
      <div style={{ color: '#8b949e', fontSize: 14, textAlign: 'center', maxWidth: 400, lineHeight: 1.7 }}>
        {active} of {total} sessions active. A slot opens in ~
        <strong style={{ color: '#58a6ff' }}>{mins} min</strong>.
        <br />Auto-retrying in <strong style={{ color: '#3fb950' }}>{countdown}s</strong>…
      </div>
      <div style={{ width: 320, background: 'rgba(48,54,61,0.5)', borderRadius: 8, height: 6, overflow: 'hidden' }}>
        <div style={{
          width: `${pct}%`, height: '100%',
          background: 'linear-gradient(90deg, #f85149, #d29922)',
          borderRadius: 8, transition: 'width 0.3s',
        }} />
      </div>
      <div style={{ fontSize: 12, color: '#484f58' }}>{active}/{total} slots used</div>
      <button
        onClick={onRetry} disabled={isRetrying}
        style={{
          background: 'rgba(88,166,255,0.1)', border: '1px solid rgba(88,166,255,0.3)',
          borderRadius: 8, color: '#58a6ff', fontSize: 13, padding: '10px 24px',
          cursor: 'pointer',
        }}
      >
        {isRetrying ? 'Checking…' : 'Check Now'}
      </button>
    </div>
  )
}

// ── Landing Page ──────────────────────────────────────────────────
export default function LandingPage() {
  const navigate = useNavigate()
  const { session, isChecking, isCreating, error, waitInfo, createSession } = useSession()
  const [termLine, setTermLine] = useState(0)
  const [provStep, setProvStep] = useState(0)

  // Redirect when session is ready
  useEffect(() => {
    if (!isChecking && session?.status === 'ready') navigate('/ide', { replace: true })
  }, [isChecking, session, navigate])

  // Advance provisioning steps while creating
  useEffect(() => {
    if (!isCreating) { setProvStep(0); return }
    const t = setInterval(() => {
      setProvStep(s => Math.min(s + 1, PROVISION_STEPS.length - 1))
    }, 3000)
    return () => clearInterval(t)
  }, [isCreating])

  // Animate terminal demo lines
  const LINES = [
    { text: '$ ls -la workspace/', color: '#3fb950' },
    { text: '  total 32   script.sh  hello.sh  data.txt', color: '#8b949e' },
    { text: '$ bash script.sh --env prod', color: '#3fb950' },
    { text: '  Deploying to prod...  [✓] Done in 2.1s', color: '#58a6ff' },
    { text: '$ grep -r "ERROR" /var/log/ | wc -l', color: '#3fb950' },
    { text: '  0', color: '#e6edf3' },
  ]
  useEffect(() => {
    if (termLine >= LINES.length) return
    const t = setTimeout(() => setTermLine(l => l + 1), 500 + termLine * 150)
    return () => clearTimeout(t)
  }, [termLine, LINES.length])

  const handleLaunch = useCallback(async () => { await createSession() }, [createSession])

  return (
    <div style={{
      minHeight: '100vh', background: '#060a0f', color: '#e6edf3',
      fontFamily: "'Space Grotesk', sans-serif", overflowX: 'hidden',
    }}>
      {/* Ambient glows */}
      <div style={{
        position: 'fixed', inset: 0, pointerEvents: 'none', zIndex: 0,
        background: `
          radial-gradient(ellipse 80% 50% at 20% -10%, rgba(88,166,255,0.07) 0%, transparent 60%),
          radial-gradient(ellipse 60% 40% at 85% 110%, rgba(188,140,255,0.06) 0%, transparent 60%)
        `,
      }} />

      {/* Nav */}
      <nav style={{
        position: 'sticky', top: 0, zIndex: 50,
        display: 'flex', alignItems: 'center', padding: '0 40px', height: 60,
        background: 'rgba(6,10,15,0.85)', backdropFilter: 'blur(16px)',
        borderBottom: '1px solid rgba(48,54,61,0.5)',
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{
            width: 30, height: 30,
            background: 'linear-gradient(135deg, #58a6ff 0%, #bc8cff 100%)',
            borderRadius: 8, display: 'flex', alignItems: 'center',
            justifyContent: 'center', fontSize: 15, fontWeight: 800, color: '#060a0f',
          }}>$</div>
          <span style={{ fontWeight: 700, fontSize: 18, letterSpacing: '-0.02em' }}>BashForge</span>
        </div>
        <div style={{ marginLeft: 'auto' }}>
          <button
            onClick={handleLaunch}
            disabled={isCreating || isChecking}
            style={{
              background: 'rgba(88,166,255,0.1)', border: '1px solid rgba(88,166,255,0.3)',
              borderRadius: 8, color: '#58a6ff', fontSize: 13, fontWeight: 500,
              padding: '8px 20px', cursor: isCreating || isChecking ? 'wait' : 'pointer',
            }}
          >
            {isCreating ? 'Launching…' : 'Open Terminal →'}
          </button>
        </div>
      </nav>

      {/* Hero */}
      <section style={{
        position: 'relative', zIndex: 1,
        display: 'flex', flexDirection: 'column', alignItems: 'center',
        padding: '96px 24px 72px', textAlign: 'center',
      }}>
        {/* Live badge */}
        <div style={{
          display: 'inline-flex', alignItems: 'center', gap: 8,
          background: 'rgba(63,185,80,0.08)', border: '1px solid rgba(63,185,80,0.2)',
          borderRadius: 20, padding: '5px 16px', fontSize: 11,
          color: '#3fb950', letterSpacing: '0.1em', textTransform: 'uppercase',
          marginBottom: 32, fontWeight: 600,
        }}>
          <span style={{ width: 6, height: 6, borderRadius: '50%', background: '#3fb950', boxShadow: '0 0 8px #3fb950', flexShrink: 0 }} />
          Isolated Linux Container · ECS Fargate
        </div>

        <h1 style={{
          fontSize: 'clamp(42px, 6vw, 78px)', fontWeight: 700,
          lineHeight: 1.06, letterSpacing: '-0.04em',
          marginBottom: 24, maxWidth: 820,
        }}>
          <span style={{ color: '#e6edf3' }}>A real shell.</span>
          <br />
          <span style={{
            background: 'linear-gradient(135deg, #58a6ff 0%, #bc8cff 100%)',
            WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
          }}>In your browser.</span>
        </h1>

        <p style={{
          fontSize: 18, color: '#8b949e', maxWidth: 500,
          lineHeight: 1.7, marginBottom: 48,
        }}>
          Spin up an isolated Linux container and run bash scripts in a full IDE —
          editor, terminal, and output panel, all in one tab.
        </p>

        {error && (
          <div style={{
            marginBottom: 24, padding: '10px 20px',
            background: 'rgba(248,81,73,0.08)', border: '1px solid rgba(248,81,73,0.3)',
            borderRadius: 8, color: '#f85149', fontSize: 13,
          }}>
            {error} — please try again.
          </div>
        )}

        {/* Launch CTA */}
        <button
          onClick={handleLaunch}
          disabled={isCreating || isChecking}
          style={{
            background: 'linear-gradient(135deg, #58a6ff 0%, #79c0ff 100%)',
            border: 'none', borderRadius: 12, color: '#060a0f',
            fontSize: 17, fontWeight: 700, padding: '17px 48px',
            cursor: isCreating || isChecking ? 'wait' : 'pointer',
            display: 'flex', alignItems: 'center', gap: 10,
            boxShadow: '0 0 48px rgba(88,166,255,0.2)',
            transition: 'opacity 0.15s, transform 0.15s',
            opacity: isCreating || isChecking ? 0.8 : 1,
            marginBottom: 16,
          }}
          onMouseEnter={e => { if (!isCreating && !isChecking) (e.currentTarget as HTMLElement).style.transform = 'translateY(-1px)' }}
          onMouseLeave={e => { (e.currentTarget as HTMLElement).style.transform = 'translateY(0)' }}
        >
          {isCreating || isChecking ? (
            <>
              <div style={{
                width: 16, height: 16, borderRadius: '50%',
                border: '2px solid rgba(0,0,0,0.25)', borderTopColor: '#000',
                animation: 'spin 0.6s linear infinite',
              }} />
              Launching…
            </>
          ) : <>&nbsp;▶&nbsp;&nbsp;Launch Terminal</>}
        </button>
        <span style={{ fontSize: 12, color: '#484f58' }}>
          Free · No account needed · 1-hour session
        </span>

        {/* Terminal preview card */}
        <div style={{
          marginTop: 64, width: '100%', maxWidth: 640,
          background: 'rgba(1,4,9,0.9)',
          border: '1px solid rgba(48,54,61,0.8)',
          borderRadius: 14, overflow: 'hidden',
          boxShadow: '0 32px 80px rgba(0,0,0,0.5)',
        }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '11px 16px', borderBottom: '1px solid rgba(48,54,61,0.5)',
            background: 'rgba(22,27,34,0.7)',
          }}>
            {['#f85149', '#d29922', '#3fb950'].map((c, i) => (
              <div key={i} style={{ width: 11, height: 11, borderRadius: '50%', background: c }} />
            ))}
            <span style={{ marginLeft: 8, color: '#484f58', fontSize: 12, fontFamily: 'JetBrains Mono' }}>
              bashuser@bashforge:~/workspace
            </span>
          </div>
          <div style={{
            padding: '16px 20px', fontFamily: 'JetBrains Mono',
            fontSize: 13, minHeight: 148, textAlign: 'left',
          }}>
            {LINES.slice(0, termLine).map((line, i) => (
              <div key={i} style={{ color: line.color, marginBottom: 4, lineHeight: 1.6 }}>
                {line.text}
              </div>
            ))}
            {termLine < LINES.length && (
              <span style={{ color: '#3fb950' }}>$ </span>
            )}
            <span style={{
              display: 'inline-block', width: 8, height: 14,
              background: '#58a6ff', marginLeft: 1, verticalAlign: 'middle',
              animation: 'blink 1s step-end infinite',
            }} />
          </div>
        </div>
      </section>

      {/* Feature grid */}
      <section style={{
        position: 'relative', zIndex: 1,
        maxWidth: 960, margin: '0 auto', padding: '0 24px 100px',
      }}>
        <div style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
          gap: 16,
        }}>
          {FEATURES.map(f => (
            <div key={f.title} style={{
              background: 'rgba(13,17,23,0.8)',
              border: '1px solid rgba(48,54,61,0.5)',
              borderRadius: 12, padding: '22px 20px',
              transition: 'border-color 0.15s',
            }}
              onMouseEnter={e => (e.currentTarget.style.borderColor = 'rgba(88,166,255,0.35)')}
              onMouseLeave={e => (e.currentTarget.style.borderColor = 'rgba(48,54,61,0.5)')}
            >
              <div style={{ fontSize: 24, marginBottom: 12 }}>{f.icon}</div>
              <div style={{ fontWeight: 600, marginBottom: 6, color: '#e6edf3', fontSize: 15 }}>{f.title}</div>
              <div style={{ fontSize: 13, color: '#8b949e', lineHeight: 1.6 }}>{f.desc}</div>
            </div>
          ))}
        </div>
      </section>

      {/* Provisioning overlay */}
      {isCreating && <ProvisioningOverlay step={provStep} />}

      {/* Capacity overlay */}
      {waitInfo && !isCreating && (
        <WaitingState
          active={waitInfo.active}
          total={waitInfo.totalSlots}
          waitSeconds={waitInfo.waitSeconds}
          onRetry={handleLaunch}
          isRetrying={isCreating}
        />
      )}

      <footer style={{
        textAlign: 'center', padding: '24px', position: 'relative', zIndex: 1,
        borderTop: '1px solid rgba(48,54,61,0.4)', color: '#484f58', fontSize: 12,
      }}>
        BashForge · Isolated ECS container per session · 1 vCPU · 512 MB RAM · 1-hour TTL
      </footer>

      <style>{`
        @keyframes spin  { to { transform: rotate(360deg); } }
        @keyframes blink { 0%,100%{opacity:1} 50%{opacity:0} }
        @keyframes pulse { 0%,100%{opacity:0.4;transform:scale(0.8)} 50%{opacity:1;transform:scale(1.2)} }
      `}</style>
    </div>
  )
}

const FEATURES = [
  { icon: '🐧', title: 'Full Linux Environment', desc: 'Real bash shell with curl, git, sed, awk, grep and all standard GNU tools pre-installed.' },
  { icon: '⌨️', title: 'Monaco Editor', desc: 'VS Code-grade editor with bash syntax highlighting, multi-cursor, snippets, and Ctrl+Enter to run.' },
  { icon: '📦', title: 'ECS Fargate Container', desc: 'Your own isolated AWS ECS task. Resource-limited and ephemeral — gone when the session ends.' },
  { icon: '↕️', title: 'Split-Pane Layout', desc: 'Editor, script output, and interactive terminal — all visible simultaneously.' },
  { icon: '⏱️', title: '1-Hour Sessions', desc: 'Close the tab and come back. Your container stays alive for a full hour.' },
  { icon: '🌐', title: 'Live Network Access', desc: 'curl, wget, git clone all work. Practice against real APIs and endpoints.' },
]
