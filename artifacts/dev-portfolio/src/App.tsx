import { useState, type CSSProperties, type MouseEvent } from 'react';
import {
  ArrowDown,
  ArrowDownRight,
  ArrowUpRight,
  Asterisk,
  Github,
  Linkedin,
  Mail,
  Menu,
  MoveUpRight,
  X,
} from 'lucide-react';
import { approach, capabilities, portfolio, projects } from './data/portfolio';

const navigation = [
  { href: '#work', label: 'Selected work' },
  { href: '#about', label: 'A little about me' },
  { href: '#approach', label: 'How I work' },
];

function ProjectArtwork({ art, label }: { art: string; label: string }) {
  return (
    <div className={`project-art art-${art}`} role="img" aria-label={label}>
      {art === 'fieldnotes' && (
        <div className="field-window">
          <div className="field-top"><span>FIELDNOTES</span><span className="field-dot" /></div>
          <div className="field-body">
            <div className="field-sidebar"><i /><i /><i /><i /></div>
            <div className="field-page">
              <span className="field-kicker">RESEARCH / 04</span>
              <div className="field-title">A better<br />kind of curious.</div>
              <div className="field-lines"><i /><i /><i /></div>
              <div className="field-sticky">listen<br />closely</div>
            </div>
          </div>
        </div>
      )}
      {art === 'common' && (
        <div className="common-layout">
          <span className="common-mark">COMMON<br />GROUND</span>
          <div className="common-sun" />
          <div className="common-vase"><span /></div>
          <span className="common-caption">Objects with a point of view</span>
          <span className="common-index">NO. 014 — 027</span>
        </div>
      )}
      {art === 'openhouse' && (
        <div className="open-layout">
          <div className="open-label">YOUR BLOCK, YOUR VOICE.</div>
          <div className="open-map">
            <span className="map-road road-one" /><span className="map-road road-two" />
            <span className="map-road road-three" /><span className="map-road road-four" />
            <span className="map-park" /><span className="map-pin pin-one" /><span className="map-pin pin-two" />
          </div>
          <div className="open-card"><span>IDEA #18</span><strong>More room<br />to meet.</strong><i>26 neighbors agree</i></div>
          <span className="open-coord">40°43'12.8"N&nbsp; 73°59'18.4"W</span>
        </div>
      )}
    </div>
  );
}

function App() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [tilt, setTilt] = useState({ x: 0, y: 0 });
  const heroStyle = {
    '--tilt-x': `${tilt.x}deg`,
    '--tilt-y': `${tilt.y}deg`,
  } as CSSProperties;

  function moveObject(event: MouseEvent<HTMLDivElement>) {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width - 0.5;
    const y = (event.clientY - rect.top) / rect.height - 0.5;
    setTilt({ x: -y * 10, y: x * 13 });
  }

  return (
    <main className="portfolio-shell grain">
      <header className="site-header">
        <a className="brand focus-ring" href="#top" aria-label={`${portfolio.name}, home`} data-testid="link-home">
          <span className="brand-mark"><Asterisk size={21} strokeWidth={1.7} /></span>
          <span>{portfolio.name.split(' ')[0]}<span className="brand-period">.</span></span>
        </a>
        <nav className={`desktop-nav ${menuOpen ? 'nav-open' : ''}`} aria-label="Main navigation">
          {navigation.map((item) => (
            <a key={item.href} href={item.href} className="nav-link focus-ring" onClick={() => setMenuOpen(false)} data-testid={`link-nav-${item.href.slice(1)}`}>
              {item.label}
            </a>
          ))}
          <a href="#contact" className="nav-contact focus-ring" onClick={() => setMenuOpen(false)} data-testid="link-nav-contact">
            Let’s talk <ArrowUpRight size={14} />
          </a>
        </nav>
        <button
          className="menu-toggle focus-ring"
          type="button"
          aria-label={menuOpen ? 'Close navigation' : 'Open navigation'}
          aria-expanded={menuOpen}
          onClick={() => setMenuOpen((open) => !open)}
          data-testid="button-mobile-menu"
        >
          {menuOpen ? <X size={21} /> : <Menu size={21} />}
        </button>
      </header>

      <section className="hero" id="top" aria-labelledby="hero-title">
        <div className="hero-copy">
          <div className="eyebrow reveal"><span className="status-dot" /> {portfolio.role} <span className="eyebrow-divider">/</span> {portfolio.location}</div>
          <h1 className="display hero-title reveal reveal-d1" id="hero-title">
            Good ideas<br />
            <span className="hero-line-two">need <em>good</em></span><br />
            <span className="hero-last">software.</span>
          </h1>
          <div className="hero-bottom reveal reveal-d2">
            <p>{portfolio.intro}</p>
            <a className="round-link focus-ring" href="#work" aria-label="Explore selected work" data-testid="link-explore-work">
              <ArrowDown size={19} />
            </a>
          </div>
        </div>

        <div className="hero-visual reveal reveal-d2" onMouseMove={moveObject} onMouseLeave={() => setTilt({ x: 0, y: 0 })}>
          <div className="hero-visual-meta mono"><span>INDEPENDENT BY DESIGN</span><span>EST. [YEAR]</span></div>
          <div className="hero-orbit" aria-hidden="true">
            <div className="hero-object" style={{ ...heroStyle, transform: `rotateX(${tilt.x}deg) rotateY(${tilt.y}deg)` }}>
              <div className="orbit-ring" />
              <div className="hero-disc" />
              <div className="hero-sphere"><div className="sphere-cut" /></div>
              <div className="object-shadow" />
            </div>
          </div>
          <div className="float-note note-top mono">A LITTLE<br />CURIOSITY ↗</div>
          <div className="float-note delay note-bottom"><Asterisk className="note-star" size={27} strokeWidth={1.4} /><span>Make useful<br />things feel good.</span></div>
          <div className="visual-foot mono"><span>FIG. 01 — AN OBJECT IN MOTION</span><span>MOVE YOUR CURSOR</span></div>
        </div>
        <div className="hero-index mono">01 <span /> 04</div>
      </section>

      <div className="ticker" aria-label="Design, engineering, and a little bit of both">
        <div className="marquee-track" aria-hidden="true">
          {[0, 1].map((copy) => <div className="ticker-group" key={copy}>
            <span>DESIGN WITH INTENT</span><Asterisk /><span>ENGINEER WITH CARE</span><Asterisk /><span>MAKE IT HUMAN</span><Asterisk /><span>STAY CURIOUS</span><Asterisk />
          </div>)}
        </div>
      </div>

      <section className="work-section section-wrap" id="work" aria-labelledby="work-title">
        <div className="section-heading">
          <div><span className="section-kicker mono">01 — A FEW THINGS I’VE MADE</span><h2 className="display" id="work-title">Selected <em>work</em></h2></div>
          <p>Good work comes from good questions.<br />Here are a few answers, in progress.</p>
        </div>
        <div className="projects-list">
          {projects.map((project) => (
            <article className={`project-card project-${project.art}`} key={project.number} data-testid={`card-project-${project.art}`}>
              <a className="project-link focus-ring" href={project.href} target="_blank" rel="noreferrer" aria-label={`Visit ${project.name} project (sample link)`} data-testid={`link-project-${project.art}`}>
                <ProjectArtwork art={project.art} label={project.label} />
                <div className="project-info">
                  <div className="project-heading">
                    <span className="project-number mono">{project.number} / {project.year}</span>
                    <h3 className="display">{project.name}<MoveUpRight size={20} strokeWidth={1.5} /></h3>
                    <span className="project-category">{project.category}</span>
                  </div>
                  <div className="project-description"><p>{project.summary}</p><div className="project-tags">{project.stack.map((tag) => <span key={tag}>{tag}</span>)}</div></div>
                </div>
              </a>
            </article>
          ))}
        </div>
        <p className="sample-note mono">PROJECTS ABOVE ARE EDITABLE CONCEPT EXAMPLES — REPLACE WITH VERIFIED WORK.</p>
      </section>

      <section className="about-section" id="about" aria-labelledby="about-title">
        <div className="about-backdrop display" aria-hidden="true">ABOUT</div>
        <div className="section-wrap about-inner">
          <div className="about-label"><span className="section-kicker mono">02 — THE PERSON BEHIND THE PIXELS</span><span className="about-coordinate mono">[YOUR CITY] · AVAILABLE WORLDWIDE</span></div>
          <div className="about-content">
            <h2 className="display" id="about-title">Hello, I’m <span className="underlined">{portfolio.name.split(' ')[0]}.</span><br />I like the <em>whole</em><br />picture.</h2>
            <div className="about-aside"><p>{portfolio.about}</p><p className="about-edit-note">This is sample copy. Make it yours before launch.</p><a className="text-link focus-ring" href={portfolio.links.resume} target="_blank" rel="noreferrer" data-testid="link-resume">A little more about me <ArrowUpRight size={16} /></a></div>
          </div>
          <div className="about-footer"><span className="about-seal"><Asterisk size={25} /><span>CURIOUS<br />BY NATURE</span></span><p>Good collaboration is equal parts<br />clear thinking and good energy.</p><span className="about-foot-index mono">A / 01</span></div>
        </div>
      </section>

      <section className="capabilities-section section-wrap" aria-labelledby="capabilities-title">
        <div className="capabilities-intro">
          <span className="section-kicker mono">WHAT I BRING TO THE TABLE</span>
          <h2 className="display" id="capabilities-title">A useful mix<br />of <em>left + right.</em></h2>
          <p>From the first conversation to the last little polish, I like connecting the dots between what a product does and how it makes people feel.</p>
        </div>
        <div className="capabilities-cloud">
          {capabilities.map((capability, index) => <span className={`skill-pill skill-${index + 1}`} key={capability}>{capability}<sup>0{index + 1}</sup></span>)}
          <span className="capabilities-note mono">THINK / MAKE / REFINE</span>
        </div>
      </section>

      <section className="approach-section" id="approach" aria-labelledby="approach-title">
        <div className="section-wrap">
          <div className="section-heading approach-heading">
            <div><span className="section-kicker mono">03 — NO MYSTERY, JUST MOMENTUM</span><h2 className="display" id="approach-title">Good work, <em>together.</em></h2></div>
            <p>Small, thoughtful steps.<br />A shared sense of where we’re going.</p>
          </div>
          <div className="approach-grid">
            {approach.map((step) => <article className="approach-step" key={step.number}>
              <span className="approach-number mono">{step.number}<span /></span>
              <h3 className="display">{step.title}</h3>
              <p>{step.text}</p>
            </article>)}
          </div>
          <div className="approach-bottom"><span className="mono">A SIMPLE PROCESS IS A KIND PROCESS.</span><Asterisk size={22} /></div>
        </div>
      </section>

      <section className="note-section section-wrap" aria-label="A small note">
        <span className="note-mark display">“</span>
        <blockquote className="display">The best software doesn’t ask for attention.<br /><em>It gives people more of it.</em></blockquote>
        <div className="note-attribution"><span className="mono">A NOTE TO SELF</span><span className="note-rule" /><span>And a north star for the work.</span></div>
      </section>

      <section className="contact-section section-wrap" id="contact" aria-labelledby="contact-title">
        <div className="contact-panel">
          <div className="contact-topline mono"><span>04 — YOUR TURN</span><span>{portfolio.availability}</span></div>
          <div className="contact-main">
            <div><span className="contact-kicker">Have a good one?</span><h2 className="display" id="contact-title">Let’s make<br /><em>it real.</em></h2></div>
            <div className="contact-cta">
              <p>Tell me what you’re thinking. The early, messy version is usually the best place to start.</p>
              <a className="email-link focus-ring" href={`mailto:${portfolio.email}?subject=Let%27s%20make%20something%20good`} data-testid="link-email">
                {portfolio.email}<ArrowUpRight size={19} />
              </a>
              <span className="email-note mono">EDIT THIS ADDRESS BEFORE PUBLISHING</span>
            </div>
          </div>
          <div className="contact-bottom">
            <span className="contact-signoff">No pitch deck required. Just say hello.</span>
            <div className="social-links">
              <a className="focus-ring" href={portfolio.links.github} target="_blank" rel="noreferrer" aria-label="GitHub profile (edit placeholder link)" data-testid="link-github"><Github size={17} /> GitHub <ArrowUpRight size={13} /></a>
              <a className="focus-ring" href={portfolio.links.linkedin} target="_blank" rel="noreferrer" aria-label="LinkedIn profile (edit placeholder link)" data-testid="link-linkedin"><Linkedin size={17} /> LinkedIn <ArrowUpRight size={13} /></a>
            </div>
          </div>
          <div className="contact-watermark display" aria-hidden="true">HELLO</div>
        </div>
      </section>

      <footer className="site-footer section-wrap">
        <a className="footer-brand focus-ring" href="#top" data-testid="link-footer-top"><Asterisk size={19} /> BACK TO THE TOP <ArrowDownRight size={14} /></a>
        <span className="footer-credit">Made with care, somewhere on this planet.</span>
        <span className="footer-year mono">© [YEAR] {portfolio.name.toUpperCase()}</span>
      </footer>
      <a className="mobile-mail focus-ring" href={`mailto:${portfolio.email}`} aria-label={`Email ${portfolio.name}`} data-testid="link-mobile-email"><Mail size={19} /></a>
    </main>
  );
}

export default App;
