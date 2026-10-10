/**
 * Editable sample content for the portfolio.
 * Replace these values with the owner's real details before publishing.
 * Kept separate from presentation so it can later be supplied by a MERN API.
 */
export const portfolio = {
  name: 'Alex Morgan',
  role: 'Independent full-stack developer',
  location: 'Available worldwide · based in [Your city]',
  email: 'hello@yourdomain.dev',
  intro:
    'I build thoughtful digital products for people with something good to put into the world.',
  about:
    'I’m an independent developer who likes the whole picture: the first sketch, the careful engineering, and the small details that make a product feel unmistakably human. I partner with curious teams to turn ambitious ideas into useful, durable software.',
  availability: 'Taking on select projects for [Season, Year]',
  links: {
    github: 'https://github.com/your-handle',
    linkedin: 'https://www.linkedin.com/in/your-handle',
    resume: 'https://example.com/your-resume.pdf',
  },
};

export const projects = [
  {
    number: '01',
    name: 'Fieldnotes',
    category: 'Product design · Full-stack',
    summary:
      'A calmer way for small teams to gather research, connect the dots, and keep the useful bits close.',
    year: '2025',
    stack: ['React', 'TypeScript', 'Node.js'],
    href: 'https://example.com/fieldnotes',
    art: 'fieldnotes',
    label: 'Fieldnotes research workspace interface concept',
  },
  {
    number: '02',
    name: 'Common Ground',
    category: 'E-commerce · Creative technology',
    summary:
      'A story-led shop for independent makers, designed to make a slower kind of discovery feel effortless.',
    year: '2024',
    stack: ['Next.js', 'Commerce', 'Motion'],
    href: 'https://example.com/common-ground',
    art: 'common',
    label: 'Common Ground editorial storefront concept',
  },
  {
    number: '03',
    name: 'Openhouse',
    category: 'Civic tech · Application',
    summary:
      'A neighborhood planning tool that gives local voices a clearer seat at the table.',
    year: '2024',
    stack: ['React', 'Express', 'PostgreSQL'],
    href: 'https://example.com/openhouse',
    art: 'openhouse',
    label: 'Openhouse neighborhood planning application concept',
  },
];

export const capabilities = [
  'Product thinking',
  'Frontend systems',
  'React & TypeScript',
  'Node.js & APIs',
  'Interaction design',
  'Design systems',
  'Prototyping',
  'Performance',
];

export const approach = [
  {
    number: '01',
    title: 'Get close to the problem',
    text: 'We start with the people, constraints, and little moments that matter. No ceremony for ceremony’s sake.',
  },
  {
    number: '02',
    title: 'Make the shape visible',
    text: 'A rough prototype is a great conversation. We find the right direction before making it production-ready.',
  },
  {
    number: '03',
    title: 'Build it to last',
    text: 'Clear code, considered details, and a handoff that leaves your team feeling confident.',
  },
];
